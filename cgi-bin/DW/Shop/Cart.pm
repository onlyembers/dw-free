#!/usr/bin/perl
#
# DW::Shop::Cart
#
# Encapsulates a shopping cart for a user.  Handles loading, saving, modifying
# and all other actions of a shopping cart.
#
# Authors:
#      Mark Smith <mark@dreamwidth.org>
#      Janine Costanzo <janine@netrophic.com>
#
# Copyright (c) 2009 by Dreamwidth Studios, LLC.
#
# This program is free software; you may redistribute it and/or modify it under
# the same terms as Perl itself.  For a copy of the license, please reference
# 'perldoc perlartistic' or 'perldoc perlgpl'.
#

package DW::Shop::Cart;

use strict;
use Carp qw/ croak confess /;
use Storable qw/ nfreeze thaw /;

use DW::Shop;

# returns a created cart for a given shop
sub get {
    my ( $class, $shop ) = @_;

    # see if the shop has a user or if it's anonymous
    my ( $u, $sql, @bind );
    if ( $shop->anonymous ) {
        # if they don't have a unique cookie and they're anonymous, we aren't
        # presently equipped to let them shop
        my $uniq = LJ::UniqCookie->current_uniq
            or return undef;

        # FIXME: we should memcache carts for people who aren't logged in

        $sql = 'uniq = ? AND userid IS NULL';
        @bind = ( $uniq );

    } else {
        $u = $shop->u
            or confess 'shop has no user object';

        # return this cart if loaded already
        return $u->{_cart} if $u->{_cart};

        # see if this user has an active cart in memcache
        my $cart = $u->memc_get( 'cart' );
        return $u->{_cart} = $cart
            if $cart;

        # faaail, have to load it
        $sql = 'userid = ?';
        @bind = ( $u->id );
    }

    # see if they had one in the database
    my $dbh = LJ::get_db_writer()
        or return undef;
    my $dbcart = $dbh->selectrow_hashref(
        qq{SELECT cartblob
           FROM shop_carts
           WHERE $sql AND state = ?
           ORDER BY starttime DESC
           LIMIT 1},
        undef, @bind, $DW::Shop::STATE_OPEN
    );

    # if we got something, thaw the blob and return
    if ( $dbcart ) {
        my $cart = $class->_build( thaw( $dbcart->{cartblob} ) );
        if ( $u ) {
            $u->{_cart} = $cart;
            $u->memc_set( cart => $cart );
        }
        return $cart;
    }

    # no existing cart, so build a new one \o/
    return $class->new_cart( $u );
}


# returns a new cart given a cartid
sub get_from_cartid {
    my ( $class, $cartid ) = @_;
    return undef
        unless defined $cartid && $cartid > 0;

    # see if they had one in the database
    my $dbh = LJ::get_db_writer()
        or return undef;
    my $dbcart = $dbh->selectrow_hashref(
        qq{SELECT cartblob
           FROM shop_carts WHERE cartid = ?},
        undef, $cartid
    );
    return undef unless $dbcart;

    # if we got something, thaw the blob and return
    return $class->_build( thaw( $dbcart->{cartblob} ) );
}


# returns a new cart given an ordernum
sub get_from_ordernum {
    my ( $class, $ordernum ) = @_;

    my ( $cartid, $authcode ) = ( $1+0, $2 )
        if $ordernum =~ /^(\d+)-(.+)$/;
    return undef
        unless $cartid && $cartid > 0;
    return undef
        unless $authcode && length( $authcode ) == 20;

    # see if they had one in the database
    my $cart = $class->get_from_cartid( $cartid );
    return undef
        unless $cart && $cart->authcode eq $authcode;

    # all matches, so return this cart
    return $cart;
}


# creating a new cart implicitly activates.  just so you know.  this function
# will build a new empty cart for the user.  but user is optional and we will
# build a cart for the current uniq.
sub new_cart {
    my ( $class, $u ) = @_;
    $u = LJ::want_user( $u );

    my $cartid = LJ::alloc_global_counter( 'H' )
        or return undef;

    # this is a blank cart containing no items
    my $cart = {
        cartid    => $cartid,
        starttime => time(),
        userid    => $u ? $u->id : undef,
        uniq      => LJ::UniqCookie->current_uniq,
        state     => $DW::Shop::STATE_OPEN,
        items     => [],
        total     => 0.00,
        nextscan  => 0,
        authcode  => LJ::make_auth_code( 20 ),
        paymentmethod => 0, # we don't have a payment method yet
    };

    # now, delete any old carts we don't need
    my $dbh = LJ::get_db_writer()
        or return undef;
    $dbh->do(
        q{UPDATE shop_carts SET state = ? WHERE (userid = ? OR uniq = ?) AND state = ?},
        undef, $DW::Shop::STATE_CLOSED, $cart->{userid}, $cart->{uniq}, $DW::Shop::STATE_OPEN
    );

    # build this into an object and activate it
    $cart = $class->_build( $cart );

    # now persist the cart
    $cart->save;
    $u->{_cart} = $cart if $u;

    # we're done
    return $cart;
}


# returns all carts that the given user has ever had
# can pass 'finished' opt which will omit carts in the OPEN, CLOSED, or
# CHECKOUT states
sub get_all {
    my ( $class, $u, %opts ) = @_;
    $u = LJ::want_user( $u );

    my $extra_sql = " AND state NOT IN ($DW::Shop::STATE_OPEN, $DW::Shop::STATE_CLOSED, $DW::Shop::STATE_CHECKOUT)"
        if $opts{finished};

    my $dbh = LJ::get_db_writer()
        or return undef;
    my $sth = $dbh->prepare( "SELECT cartblob FROM shop_carts WHERE userid = ?$extra_sql" );
    $sth->execute( $u->id );

    my @carts = ();
    while ( my $cart = $sth->fetchrow_hashref ) {
        push @carts, $class->_build( thaw( $cart->{cartblob} ) );
    }

    return @carts;
}


# saves the current cart to the database, returns 1/0
sub save {
    my ( $self, %opts ) = @_;

    my $memcache_data = $opts{no_memcache} ? 0 : 1;

    # we store the payment method id in the db
    my $paymentmethod_id = $DW::Shop::PAYMENTMETHODS{$self->paymentmethod}->{id} || 0;

    # toss in the database
    my $dbh = LJ::get_db_writer()
        or return undef;
    $dbh->do(
        q{REPLACE INTO shop_carts (userid, cartid, starttime, uniq, state, nextscan, authcode, paymentmethod, cartblob)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)},
        undef, ( map { $self->{$_} } qw/ userid cartid starttime uniq state nextscan authcode / ), $paymentmethod_id, nfreeze( $self )
    );

    # bail if error
    return 0 if $dbh->err;

    # also toss this in memcache
    my $u = LJ::load_userid( $self->{userid} );
    if ( $memcache_data && LJ::isu( $u ) ) {
        $u->memc_set( cart => $self );
    }

    # success!
    return 1;
}


# returns the number of items in this cart
sub num_items {
    my $self = $_[0];

    return scalar @{ $self->{items} || [] };
}


# returns 1/0 if this cart has any items in it
sub has_items {
    my $self = $_[0];

    return $self->num_items > 0 ? 1 : 0;
}


# add an item to the shopping cart, returns 1/0
sub add_item {
    my ( $self, $item ) = @_;

    # tell teh item who we are
    $item->cartid( $self->id );

    # make sure this item is allowed to be added
    my $error;
    unless ( $item->can_be_added( errref => \$error ) ) {
        return ( 0, $error );
    }

    # iterate over existing items to see if any conflict
    foreach my $it ( @{$self->items} ) {
        if ( my $rv = $it->conflicts( $item ) ) {
            # this return value is so messed up... WTB exceptions
            return ( 0, $rv );
        }
    }

    # looks good, so let's add it...
    push @{$self->items}, $item;
    $self->{total} += $item->cost;
    $item->id( $#{$self->items} );

    # save to db and return
    $self->save;
    return 1;
}


# removes an item from this cart by id
sub remove_item {
    my ( $self, $id ) = @_;

    my $out = [];
    foreach my $it ( @{$self->items} ) {
        if ( $it->id == $id ) {
            $self->{total} -= $it->cost;
        } else {
            push @$out, $it;
        }
    }

    $self->{items} = $out;
    $self->save;
    return 1;
}


# get/set state
sub state {
    my ( $self, $newstate ) = @_;

    return $self->{state}
        unless defined $newstate;

    $self->{state} = $newstate;
    $self->save;

    return $self->{state};
}


# get/set payment method
sub paymentmethod {
    my ( $self, $newpaymentmethod ) = @_;

    return $self->{paymentmethod}
        unless defined $newpaymentmethod;

    $self->{paymentmethod} = $newpaymentmethod;
    $self->save;

    return $self->{paymentmethod};
}

################################################################################
## read-only accessor methods
################################################################################


sub id       { $_[0]->{cartid}             } 
sub userid   { $_[0]->{userid}             }
sub starttime{ $_[0]->{starttime}          }
sub age      { time() - $_[0]->{starttime} }
sub items    { $_[0]->{items} ||= []       }
sub uniq     { $_[0]->{uniq}               }
sub nextscan { $_[0]->{nextscan}           }
sub authcode { $_[0]->{authcode}           }
sub total    { $_[0]->{total}+0.00         }

# returns the total in a displayed format
sub display_total { sprintf( '%0.2f', $_[0]->total ) }

# and our order number
sub ordernum { $_[0]->{cartid} . '-' . $_[0]->{authcode} }


################################################################################
## internal cart methods
################################################################################


# turns a hashref cart into a cart object
sub _build {
    my ( $class, $cart ) = @_;
    ref $cart eq 'HASH' or return $cart;

    # simply blesses ... although in the future we might do some sanity checking
    # here to make sure we have good data, if that proves to be necessary.
    return bless $cart, $class;
}


1;
