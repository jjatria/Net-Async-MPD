package AnyEvent::Net::MPD;

use strict;
use warnings;

use Moo;
use MooX::HandlesVia;
extends 'AnyEvent::Emitter';

use AnyEvent;
use AnyEvent::Socket;
use AnyEvent::Handle;
use Clone qw( clone );
use PerlX::Maybe;
use Types::Standard qw(
  InstanceOf Int ArrayRef HashRef Str Maybe Bool CodeRef
);

use Log::Any;
my $log = Log::Any->get_logger( category => __PACKAGE__ );

has version => (
  is => 'ro',
  isa => Str,
  lazy => 1,
);

has auto_connect => (
  is => 'ro',
  isa => Bool,
  default => 1,
);

has state => (
  is => 'rw',
  isa => Str,
  default => 'created',
  trigger => sub {
    $_[0]->emit( state => $_[0]->{state} );
  },
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

has [qw( handle socket )] => ( is => 'rw' );

{
  my @buffer;
  sub _parse_block {
    my $self = shift;
    return sub {
      my ($handle, $line) = @_;

      if ($line =~ /\w/) {
        $log->tracef('< %s', $line);
        if ($line =~ /^OK/) {
          if ($line =~ /OK MPD (.*)/) {
            $log->trace('Connection established');
            $self->{version} = $1;
            $self->state( 'ready' );
          }
          else {
            $self->shift_read->( \@buffer );
            @buffer = ();
          }
        }
        elsif ($line =~ /^ACK/) {
          return $self->emit(error => $line );
          @buffer = ();
        }
        else {
          push @buffer, $line;
        }
      }

      $handle->push_read( line => $self->_parse_block );
    };
  }
}

# Set up response parsers for each command
my $parsers = { none => sub { @_ } };
{
  my $item = sub {
    return { map {
      my ($key, $value) = split /: /, $_, 2;
      $key => $value;
    } @{$_[0]} };
  };

  my $flat_list = sub { [ map { (split /: /, $_, 2)[1] } @{$_[0]} ] };

  my $base_list = sub {
    my @main_keys = @{shift()};
    my @list_keys = @{shift()};
    my @lines     = @{shift()};

    my @return;
    my $item = {};

    foreach my $line (@lines) {
      my ($key, $value) = split /: /, $line, 2;

      if ( grep { /$key/ } @main_keys ) {
        push @return, $item if defined $item->{$key};
        $item = { $key => $value };
      }
      elsif ( grep { /$key/ } @list_keys ) {
        unless (defined $item->{$key}) {
          $item->{$key} = []
        }
        push @{$item->{$key}}, $value;
      }
      else {
        $item->{$key} = $value;
      }
    }
    push @return, $item if keys %{$item};

    return \@return;
  };

  my $grouped_list = sub {
    my @lines = @{shift()};

    # What we are grouping
    my ($main) = split /:\s+/, $lines[0], 2;

    # How we are grouping, from top to bottom
    my (@categories, %categories);
    foreach (@lines) {
      my ($key) = split /:\s+/, $_, 2;

      if ($key ne $main) {
        push @categories, $key unless defined $categories{$key};
        $categories{$key} = 1;
      }
    }

    my $return = {};
    my $item;
    foreach my $line (@lines) {
      my ($key, $value) = split /:\s+/, $line, 2;

      if (defined $item->{$key}) {
        # Find the appropriate list of items or create a new one
        # and populate it
        my $pointer = $return;
        foreach my $key (@categories) {
          my $val = $item->{$key} // q{};
          $pointer->{$key}{$val} = {} unless defined $pointer->{$key}{$val};
          $pointer = $pointer->{$key}{$val};
        }
        $pointer->{$main} = [] unless defined $pointer->{$main};
        my $list = $pointer->{$main};

        push @{$list}, delete $item->{$main};

        # Start a new item
        $item = { $key => $value };
        next;
      }

      $item->{$key} = $value;
    }
    return $return;
  };

  # Untested commands: what do they return?
  # consume
  # crossfade

  my $file_list = sub { $base_list->( [qw( directory file )], [], @_ ) };

  $parsers->{$_} = $flat_list foreach qw(
    commands notcommands channels tagtypes urlhandlers listplaylist
  );

  $parsers->{$_} = $item foreach qw(
    currentsong stats idle status addid update
    readcomments replay_gain_status rescan
  );

  $parsers->{$_} = $file_list foreach qw(
    find playlistinfo listallinfo search find playlistid playlistfind
    listfiles plchanges listplaylistinfo playlistsearch listfind
  );

  $parsers->{list} = $grouped_list;

  foreach (
      [ outputs        => [qw( outputid )],  [] ],
      [ plchangesposid => [qw( cpos )],      [] ],
      [ listplaylists  => [qw( playlist )],  [] ],
      [ listmounts     => [qw( mount )],     [] ],
      [ listneighbors  => [qw( neighbor )],  [] ],
      [ listall        => [qw( directory )], [qw( file )] ],
      [ readmessages   => [qw( channel )],   [qw( message )] ],
      [ lsinfo         => [qw( directory file playlist )], [] ],
      [ decoders       => [qw( plugin )], [qw( suffix mime_type )] ],
    ) {

    my ($cmd, $header, $list) = @{$_};
    $parsers->{$cmd} = sub { $base_list->( $header, $list, @_ ) };
  }

  $parsers->{playlist} = sub {
    my $lines = [ map { s/^\w*?://; $_ } @{shift()} ];
    $flat_list->( $lines, @_ )
  };

  $parsers->{count} = sub {
    my $lines = shift;
    my ($main) = split /:\s+/, $lines->[0], 2;
    $base_list->( [ $main ], [qw( )], $lines, @_ )
  };

  $parsers->{sticker} = sub {
    my $lines = shift;
    return {} unless scalar @{$lines};

    my $single = ($lines->[0] !~ /^file/);

    my $base = $base_list->( [qw( file )], [qw( sticker )], $lines, @_ );
    my $return = [ map {
      $_->{sticker} = { map { split(/=/, $_, 2) } @{$_->{sticker}} }; $_;
    } @{$base} ];

    return $single ? $return->[0] : $return;
  };
}

sub send {
  my $self = shift;
  my $opt  = ( ref $_[0] eq 'HASH' ) ? shift : {};
  my $cb = pop if ref $_[-1] eq 'CODE';
  my (@commands) = @_;

  # Normalise input
  if (ref $commands[0] eq 'ARRAY') {
    @commands = map {
      ( ref $_ eq 'ARRAY' ) ? join( q{ }, @{$_} ) : $_;
    } @{$commands[0]};
  }
  else {
    @commands = join q{ }, @commands;
  }

  my $command = '';
  # Remove underscores from command names
  @commands = map {
    my $args;
    ($command, $args) = split /\s/, $_, 2;
    $command =~ s/_//g unless $command =~ /^replay_gain_/;
    $args //= q{};
    "$command $args";
  } @commands;

  # Create block if command list
  if (scalar @commands > 1) {
    unshift @commands, "command_list_begin";
    push    @commands, "command_list_end";
  }

  my $parser = $opt->{parser} // $command;
  $parser = $parsers->{$parser} // $parsers->{none};

  my $cv = AnyEvent->condvar( maybe cb => $cb );

  $self->push_read( sub {
    my $response = shift;
    $cv->send( ( $opt->{raw} ) ? $response : $parser->( $response ) );
  });

  $log->tracef( '> %s', $_ ) foreach @commands;
  $self->handle->push_write( join("\n", @commands) . "\n" );

  return $cv;
}

sub get { shift->send( @_ )->recv }

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

sub BUILD {
  my ($self, $args) = @_;

  $self->socket( $self->_build_socket );

  $self->connect if $self->auto_connect;
}

sub _build_socket {
  my $self = shift;

  my $socket = tcp_connect $self->host, $self->port, sub {
    my ($fh) = @_
      or die "MPD connect failed: $!";

    $log->debugf('Connecting to %s:%s', $self->host, $self->port);
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

    # TODO: implement password (sent as first message after initial OK)
    $self->handle->on_read(sub {
      $self->handle->push_read( line => $self->_parse_block )
    });

    $self->handle->on_error(sub {
      my ($h, $fatal, $message) = @_;
      $self->emit( error => $message // 'Error' );
      $self->handle(undef);
    });

    $self->handle->on_eof(sub {
      my ($h, $fatal, $message) = @_;
      $self->emit( eof => $message // 'EOF' );
      $self->handle(undef);
    });
  };

  return $socket;
}

sub reconnect {
  my $self = shift;
  $self->socket( undef );
  $self->socket( $self->_build_socket );
  return $self;
}

sub connect {
  my ($self) = @_;

  return $self if $self->state eq 'ready';

  my $cv = AnyEvent->condvar;
  $self->until( state => sub { $_[1] eq 'ready' }, sub {
    $cv->send;
  });
  $cv->recv;

  return $self;
}

sub emitter {
  my ($self, @subsystems) = @_;

  my $cv = AnyEvent->condvar;
  my $idle;
  $idle = sub {
    my $o = shift->recv;
    $self->emit( $o->{changed} );
    $self->send( idle => @subsystems, $idle );
  };
  $self->send( idle => @subsystems, $idle );

  return $cv;
}

1;

__END__

=encoding UTF-8

=head1 NAME

AnyEvent::Net::MPD - A non-blocking interface to MPD

=head1 SYNOPSIS

  use AnyEvent;
  use AnyEvent::Net::MPD;

  my $mpd = AnyEvent::Net::MPD->new( host => $host );

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

AnyEvent::Net::MPD provides a non-blocking interface to an MPD server.

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

=item B<stored_playlist>

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
