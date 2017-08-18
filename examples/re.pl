#!/usr/bin/env perl

use strict;
use warnings;

use Net::Async::MPD;
use Term::ReadLine;
use PerlX::Maybe;
use Data::Printer output => 'stdout';
use IO::Async::Loop;
use IO::Async::Timer::Periodic;
use Log::Any::Adapter;

my $loop = IO::Async::Loop->new;
my $term = Term::ReadLine->new('MPD REPL');

my $mpd = Net::Async::MPD->new(
  maybe host => $ARGV[0],
  auto_connect => 1,
);

$mpd->on( error => sub {
  shift;
  die "Error: " . shift
});

$mpd->on( eof => sub {
  die "EOF received. Going away\n";
});

print "Connected to MPD (v", $mpd->version, ")\n";
my $prompt = "# ";

# Keep the connection alive
my $timer = IO::Async::Timer::Periodic->new(
  first_interval => 30,
  interval => 30,
  on_tick => sub { $mpd->send( 'ping' ) },
);

$timer->start;
$loop->add( $timer );

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

while ( defined (my $cmd = $term->readline($prompt)) ) {
  next if $cmd eq q{};
  last if $cmd =~ /^(exit|quit)$/;

  if ($cmd =~ /^(?:un)?trace$/) {
    trace($cmd);
    next;
  }

  my $future = $mpd->send( $cmd, sub {
    my $res = shift;
    my $has_data =
        ( ref $res eq 'ARRAY' ) ? scalar @{$res}
      : ( ref $res eq 'HASH' )  ? keys   %{$res}
      : $res;

    p $res if !$@ and $has_data;
    $term->addhistory($cmd) if $cmd =~ /\S/;
  });

  $future->get;
}

sub trace {
  my $cmd = shift;
  if ($cmd eq 'trace'){
    Log::Any::Adapter->set( 'Stderr', log_level => 'trace' );
  }
  else {
    Log::Any::Adapter->set( 'Null' );
  }
}