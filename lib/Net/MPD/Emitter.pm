package Net::MPD::Emitter;

use strict;
use warnings;

use Moo;
use DateTime;
use MooX::HandlesVia;
use AnyEvent;
use AnyEvent::Socket;
use AnyEvent::Handle;
use Clone qw( clone );
use DDP;
use Net::MPD;
use Types::Standard qw(
  InstanceOf Int ArrayRef HashRef Str Maybe Bool CodeRef
);
extends 'AnyEvent::Emitter';

use Log::Any;
my $log = Log::Any->get_logger( category => 'MPD' );

has version => (
  is => 'ro',
  isa => Str,
  lazy => 1,
);

has keep_alive => (
  is => 'ro',
  isa => Bool,
  default => 0,
);

has state => (
  is => 'rw',
  isa => Str,
  default => 'created',
  trigger => sub {
    $_[0]->emit( state => $_[0]->{state} );
  },
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

has _ping => (
  is => 'ro',
  init_arg => undef,
  lazy => 1,
  default => sub {
    my $self = shift;
    AnyEvent->timer(
      after    => 30,
      interval => 30,
      cb       => sub { $self->send('ping', sub {} ) },
    );
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

has read_queue => (
  is => 'ro',
  isa => ArrayRef [CodeRef],
  lazy => 1,
  default => sub { [] },
  handles_via => 'Array',
  handles => {
    push_read    => 'push',
    pop_read     => 'pop',
    shift_read   => 'shift',
    unshift_read => 'unshift',
  },
);

has _handlers => (
  is => 'ro',
  isa => HashRef,
  lazy => 1,
  default => sub {
    my $self = shift;

    my @lines;
    return {
      block => sub {
        my ($handle) = @_;

        my $done = 0;
        my @buffer = split /\n/, $handle->rbuf;

        while (my $line = shift @buffer) {
          next unless $line =~ /\w/;

          $log->tracef('< %s', $line);
          if ($line =~ /^OK/) {
            if ($line =~ /OK MPD (.*)/) {
              $log->trace('Connection established');
              $self->{version} = $1;

              $self->state( 'ready' );

              if (scalar @{$self->subsystems}) {
                $self->send( idle =>
                  @{$self->subsystems},
                  $self->_handlers->{idle},
                );
                $self->state( 'waiting' );
              }

            }
            else {
              $done = 1;
              $self->shift_read->($self, \@lines);
              @lines = ();
              last;
            }
          }
          elsif ($line =~ /^ACK/) {
            $done = 1;
#             $log->travef('GOT ACK: %s', $line);
            $self->emit( error => $line );
            @lines = ();
            last;
          }
          else {
            push @lines, $line;
          }
        }

        if ($done) {
          $handle->rbuf = q{};
          return 1;
        }
        else {
          $handle->rbuf = join "\n", @buffer;
          return [];
        }
      },
      idle => sub {
        my ($self, $response) = @_;

        # Determine idle event to trigger
        my $event = $response->[0];
        $event =~ s/changed: //;

        $log->debugf('[%s] Got an idle event: %s', DateTime->now, $event);

        # Set client as ready to send messages
        $self->state( 'ready' );

        # Request status update, and emit idle event when status is back
        $self->send( 'status', sub {
          shift;
          $self->emit( $event => shift );
        });

        # Re-register idle listeners
        if (scalar @{$self->subsystems}) {
          $self->send( idle =>
            @{$self->subsystems},
            $self->_handlers->{idle},
          );
          $self->state( 'waiting' );
        }
      },
    };
  },
);

has _socket => (
  is => 'rw',
  lazy => 1,
  default => sub {
    my ($self) = @_;
    $log->debugf('Connecting to %s:%s', $self->host, $self->port);
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
        $self->handle->push_read( $self->_handlers->{block} )
      });

      $self->handle->on_error(sub {
        my ($h, $fatal, $message) = @_;
        $self->emit( error => $message // '!!!' );
#         $self->handle(undef);
      });

      $self->handle->on_eof(sub {
        my ($h, $fatal, $message) = @_;
        $self->emit( 'close' );
        $self->handle(undef);
      });

    };
  },
);

sub send {
  my ($self, $command, @args) = @_;

  $self->push_read( pop @args ) if ref $args[-1] eq 'CODE';

  my $writer = sub {
    my $cmd = sprintf "%s %s", $command, join q{ }, @args;
    $log->tracef('> %s', $cmd);

    $self->handle->push_read( $self->_handlers->{block} );
    $self->handle->push_write( "$cmd\n" );
  };

  if ($self->state eq 'ready' ) {
    $writer->()
  }
  else {
    $self->until( state => sub { $_[1] eq 'ready' }, $writer );
  }
}

sub until {
  my ($self, $name, $check, $cb) = @_;

  weaken $self;
  my $wrapper;
  $wrapper = sub {
    if ($check->(@_)) {
      $self->unsubscribe($name => $wrapper);
      $cb->(@_);
    }
  };
  $self->on($name => $wrapper);

  return $wrapper;
}

sub get {
  my ($self, $command, @args) = @_;
  $log->debugf('Blocking command: %s %s', $command, @args);

  my $cv = AnyEvent::condvar;

  my $error = $self->once( error => sub {
    $log->warn($_[1]);
    $cv->send;
  });

  # Read response to command
  $self->unshift_read( sub {
    my ($s, $payload) = @_;

    if (scalar @{$self->subsystems}) {
      $log->debugf('Blocking %s returned', $command);

      $self->send( idle => @{$self->subsystems} );
      $self->state( 'waiting' );
    }

    $self->unsubscribe( error => $error );
    $cv->send( clone $payload );
  });

  # Read response to noidle
  if ($self->state eq 'waiting') {
    $self->unshift_read( sub { } );
    $self->send( 'noidle' );
  }

  # Set client as ready to send
  $self->state( 'ready' );

  $self->send( $command, @args );

  # Block until command returns
  return $cv->recv;
}

sub BUILD {
  my ($self, $args) = @_;

  $self->_socket;
  $self->_ping if $self->keep_alive;

  $self->on( state => sub {
    my ($s, $state) = @_;
    $log->debugf('Client is %s', $state);
  });

  my $cv = AnyEvent->condvar;
  $self->until( state => sub { $_[1] eq 'ready' }, sub {
    $cv->send;
  });
  $cv->recv;
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
