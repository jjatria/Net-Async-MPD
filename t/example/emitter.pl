#!/usr/bin/env perl

use strict;
use warnings;

use Net::Async::MPD;
use PerlX::Maybe;

# use Log::Any::Adapter;
# Log::Any::Adapter->set( 'Stderr', log_level => 'trace' );

my $mpd = Net::Async::MPD->new(
  maybe host => $ARGV[0],
  auto_connect => 1,
);

foreach my $event (qw(
    database udpate stored_playlist playlist player
    mixer output sticker subscription message
  )) {

  $mpd->on( $event => sub { print "$event changed\n" });
}

$mpd->idle->get;
