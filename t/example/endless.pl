#!/usr/bin/env perl

use strict;
use warnings;

use List::Util qw( shuffle );
use Array::Utils qw( array_minus );
use Net::Async::MPD;
use IO::Async::Loop;
use PerlX::Maybe;

my $loop = IO::Async::Loop->new;
my $mpd = Net::Async::MPD->new(
  maybe host => $ARGV[0],
  auto_connect => 1,
);

# use Log::Any::Adapter;
# Log::Any::Adapter->set( 'Stderr', log_level => 'trace' );

my $total_length = 21;
my $n = 1;
my $previous;

my @all_files;
$mpd->send( { parser => 'none' }, 'list_all', sub {
  @all_files = map { (split /:\s+/, $_, 2)[1] }
    grep { /^file:/ }
    @{ shift() };
})->get;

sub make_chain {
  return $mpd->send( idle => 'player' )
    ->then( sub {
      return $mpd->send( 'status' );
    })
    ->then( sub {
      my $status = shift;
      my $current = $status->{songid};
      $previous = $current unless defined $previous;
      if ($current ne $previous) {
        $previous = $current;
        return $mpd->send( 'playlist' );
      }
      else {
        return $loop->new_future->done;
      }
    })
    ->then( sub {
      my @playlist = @{ shift() };

      my $all_new = 1;
      my @new;
      foreach (0..100) {
        my @indeces = shuffle( 0..$#all_files );
        @new = @all_files[ @indeces[ 0 .. $n-1 ] ];

        my @diff = array_minus( @new, @playlist );
        if (scalar @diff eq $n) { last }
        else { $all_new = 0 }
      }

      warn 'Some of the added songs already exist in the playlist!'
        unless $all_new;

      my $end = scalar @playlist;
      my @commands = map { [ addid => $_, $end++ ] } @new;
      push @commands, [ delete => "0:$n" ];

      return $mpd->send( \@commands );
    })
}

while (1) { make_chain()->get }
