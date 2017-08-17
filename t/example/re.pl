#!/usr/bin/env perl

use strict;
use warnings;

use Net::Async::MPD;
use Term::ReadLine;
use PerlX::Maybe;
use Data::Printer output => 'stdout';
use IO::Async::Loop;

my $loop = IO::Async::Loop->new;

my $mpd = Net::Async::MPD->new(
  maybe host => $ARGV[0],
  auto_connect => 1,
);

print "Connected to MPD (v", $mpd->version, ")\n";
my $prompt = "# ";

my $term = Term::ReadLine->new('MPD REPL');
my $OUT = $term->OUT || \*STDOUT;

# Make readline work with inside the event loop
{
  my $input;
  $term->event_loop(
    # Wait for input
    sub {
      $input = $loop->new_future;
      $input->get;
    },
    # Register input
    sub {
      $loop->watch_io(
        handle => shift,
        on_read_ready => sub { $input->done unless $input->is_ready },
      );
    }
  );
}

while ( defined ($_ = $term->readline($prompt)) ) {
  my $cmd = $_;

  my $future = $mpd->send( $cmd, sub {
    my $res = shift;
    my $has_data =
        ( ref $res eq 'ARRAY' ) ? scalar @{$res}
      : ( ref $res eq 'HASH' )  ? keys   %{$res}
      : $res;

    p $res if !$@ and $has_data;
    $term->addhistory($cmd) if /\S/;
  });

  $future->get;
}
