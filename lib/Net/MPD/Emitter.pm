package Net::MPD::Emitter;

use strict;
use warnings;

use Moo;
use AnyEvent;
use AnyEvent::Socket;
use Clone qw( clone );
use DDP;
use Net::MPD;
use Types::Standard qw( InstanceOf Int ArrayRef HashRef Str Maybe Bool );
extends 'AnyEvent::Emitter';

use Log::Any;
my $log = Log::Any->get_logger( category => 'MPD' );

has version => (
  is => 'ro',
  isa => Str,
  lazy => 1,
);

has ready => (
  is => 'rw',
  isa => Bool,
  default => 0,
);

has status => (
  is => 'rw',
  isa => HashRef,
  default => sub { {} },
);

has password => (
  is => 'ro',
  isa => Maybe[Str],
  lazy => 1,
);

has port => (
  is => 'ro',
  isa => Int,
  lazy => 1,
  default => 6600,
);

has host => (
  is => 'ro',
  isa => Str,
  lazy => 1,
  default => sub { $ENV{MPD_HOST} // 'localhost' },
);

has _uri => (
  is => 'ro',
  init_arg => undef,
  lazy => 1,
  default => sub {
    my $self = shift;
      ( $self->password ? $self->password . '@' : q{} )
    . $self->host
    . ( $self->port     ? ':' . $self->port     : q{} )
  },
);

has event_names => (
  is => 'ro',
  isa => ArrayRef,
  lazy => 1,
  init_args => 'events',
  default => sub { [
    @{$_[0]->subsystems},
    qw( status stats song )
  ] },
);

has subsystems => (
  is => 'ro',
  isa => ArrayRef,
  lazy => 1,
  default => sub { [ qw(
    playlist update stored_playlist player mixer
    output sticker subscription message
  ) ] },
);

has handle => (
  is => 'rw',
  lazy => 1,
);

has _parser => (
  is => 'ro',
  lazy => 1,
  default => sub {
    my $self = shift;
    my @lines;
    return sub {
      my ($hdl, $line) = @_;

      $log->tracef('< %s', $line);

      chomp($line);
      if ($line =~ /^OK/) {
        $self->emit( response => [ { map { split /:\s+/, $_, 2 } @lines } ] );
        @lines = ();
      }
      elsif ($line =~ /^ACK/) {
        $log->errorf('Error: %s', $line);
        $self->emit( error => $line );
        @lines = ();
      }
      else {
        push @lines, $line;
        $self->handle->push_read( line => $self->_parser );
      }
    }
  },
);

has _socket => (
  is => 'rw',
  lazy => 1,
  default => sub {
    my ($self) = @_;
    $log->infof('Connecting to %s:%s', $self->host, $self->port);
    return tcp_connect $self->host, $self->port, sub {
      my ($fh) = @_
        or die "MPD connect failed: $!";

      $self->handle(
        AnyEvent::Handle->new(
          fh => $fh,
          on_error => sub {
            my ($hdl, $fatal, $msg) = @_;
            $self->emit( error => $msg );
            $hdl->destroy;
          },
        )
      );

      $self->handle->on_read(sub {
        $self->handle->push_read( line => sub {
          my ($h, $version) = @_;
          $log->trace('Connection established');
          $log->tracef('<<< %s', $version);
          $version =~ s/OK MPD (.*)/$1/;
          $self->{version} = $version;

          $self->send( idle => @{$self->subsystems} )
            if scalar @{$self->subsystems};

          $self->ready(1);
          $log->trace('Setting ready');
          $self->emit( 'ready' );
        });
      });

    };
  },
);

{
  my @use_song_parser = qw(
    find listall listallinfo listplaylist listplaylistinfo playlistinfo lsinfo
    search playlistfind playlistid playlistinfo playlistsearch playlistchanges
    currentsong
  );
  my @use_decoder_parser = qw( decoders );

  my @list;
  my $item = {};

  sub send {
    my ($self, $command, @args) = @_;

    my $cb;
    my ($song_parser, $decoder_parser);

    $song_parser = sub {
      my ($hdl, $line) = @_;

      if ($line =~ /^OK/) {
        push @list, $item;
        $self->emit( response => \@list );
        @list = ();
      }
      elsif ($line =~ /^ACK/) {
        $self->emit( error => $line );
      }
      else {
        my ($key, $value) = split /: /, $line, 2;
        $key = lc($key);

        if ($key =~ /^(?:file|directory|playlist)$/) {
          push @list, $item if exists $item->{type};
          $item = { type => $key, uri => $value };
        } else {
          $item->{$key} = $value;
        }

        $self->handle->push_read( line => $cb );
      }
    };

    $decoder_parser = sub {
      my ($hdl, $line) = @_;

      if ($line =~ /^OK/) {
        push @list, $item;
        $self->emit( response => \@list );
        @list = ();
      }
      elsif ($line =~ /^ACK/) {
        $self->emit( error => $line );
      }
      else {
        my ($key, $value) = split /: /, $line, 2;
        $key = lc($key);

        if ($key eq 'plugin') {
          push @list, $item if exists $item->{name};
          $item = { name => $value };
        } else {
          push @{$item->{$key}}, $value;
        }

        $self->handle->push_read( line => $cb );
      }
    };

    $cb = (ref $args[-1] eq 'CODE')
      ? pop @args
      : (grep { $_ eq $command } @use_song_parser)
        ? $song_parser
        : (grep { $_ eq $command } @use_decoder_parser)
          ? $decoder_parser
          : $self->_parser;

    my $writer = sub {
      my $cmd = sprintf "%s %s", $command, join q{ }, @args;
      $log->tracef('> %s', $cmd);
      $self->ready(0);
      $self->handle->push_read( line => $cb );
      $self->handle->push_write( "$cmd\n" );
    };

    if ($self->ready) { $writer->() }
    else { $self->once( ready => $writer ) }
  }
}

sub get {
  my ($self, $command, @args) = @_;

  $log->tracef('Getting %s', $command);
  my $cv = AnyEvent::condvar;
  $self->once( response => sub {
    my ($s, $payload) = @_;
    $cv->send( clone $payload );
  });
  $self->send( $command, @args );
  return $cv->recv;
}

sub BUILD {
  my ($self, $args) = @_;
  $self->_socket;

  $self->on( status => sub {
    my ($s, $status) = @_;
    $self->status($status);
  });

  $self->on( response => sub {
    my ($s, $payload) = @_;

    if (defined $payload->[0]{changed}) {
      my $event = $payload->[0]{changed};
      my $current = $self->status->{songid};

      $self->once( status => sub {
        my ($s, $status) = @_;
        $log->tracef('Emitting %s', $event);
        $self->emit( $event => $status );

        $log->tracef('Emitting song');
        $self->emit( song => $status )
          if $event eq 'player'
            and ($current // q{}) ne ($status->{songid} // q{});
      });
      $self->send('status');

      $self->send( idle => @{$self->subsystems} );
    }
    elsif (defined $payload->[0]{state}) {
      $log->tracef('Emitting status');
      $self->emit( status => $payload->[0] );
    }
    elsif (defined $payload->[0]{playtime}) {
      $log->tracef('Emitting stats');
      $self->emit( stats => $payload->[0] );
    }

    $self->ready(1);
    $self->emit('ready');
  });
}

1;

__END__


=encoding utf8

=head1 NAME

Net::MPD::Emitter - A non-blocking interface to MPD

=head1 SYNOPSIS

  use AnyEvent;
  use Net::MPD::Emitter;

  my $mpd = Net::MPD::Emitter->new( host => $host );

  # Register a listener
  $mpd->on( song => sub {
    my ($self, $status) = @_;
    print "The song has changed\n";
  });

  # Send a command
  $mpd->send( 'next' );

  # Or in blocking mode
  # Although you should probably not mix the two interfaces
  my $status = $mpd->get( 'status');

  AnyEvent->condvar->recv;

=head1 DESCRIPTION

Net::MPD::Emitter provides a non-blocking interface to an MPD server.

=head1 ATTRIBUTES

=over 4

=item B<host>

=item B<subsystems>

=item B<events>

=item B<port>

=item B<password>

=back

=head1 EVENTS

There are events per subsystem:

=over 4

=item B<database>

The song database has been changed after an update.

=item B<udpate>

A database update has started or finished.

=item B<stored>_playlist

A stored playlist has been modified.

=item B<playlist>

The current playlist has been modified.

=item B<player>

Playback has been started stopped or seeked.

=item B<mixer>

The volume has been adjusted.

=item B<output>

An audio output has been enabled or disabled.

=item B<sticker>

The sticket database has been modified.

=item B<subscription>

A client has subscribed or unsubscribed from a channel.

=item B<message>

A message was received on a channel this client is watching.

=back

As well as some events specifc to this distribution:

=over 4

=item B<song>

=item B<status>

=item B<stats>

=item B<response>

=item B<error>

=back

=head1 AUTHOR

=over 4

=item *

José Joaquín Atria <jjatria@cpan.org>

=back

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2017 by José Joaquín Atria.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut
