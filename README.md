# NAME

Net::Async::MPD - A non-blocking interface to MPD

# SYNOPSIS

    use Net::Async::MPD;

    my $mpd = Net::Async::MPD->new( host => $ARGV[0] )->connect;

    my @subsystems = qw( player mixer database );

    # Register a listener
    foreach my $subsystem (@subsystems) {
      $mpd->on( $subsystem => sub {
        my ($self) = @_;
        print "$subsystem has changed\n";

        # Stop listening if mixer changes
        $mpd->noidle if $subsystem eq 'mixer';
      });
    }

    # Send a command
    my $stats = $mpd->send( 'stats' );

    # Or in blocking mode
    my $status = $mpd->send( 'status' )->get;

    # Which is the same as
    $status = $mpd->get( 'status' );

    print "Server is ", $status->{state}, " state\n";
    print "Server has ", $stats->get->{albums}, " albums in the database\n";

    # Put the client in looping idle mode
    my $idle = $mpd->idle( @subsystems );

    # Set the emitter in motion, until the next call to noidle
    $idle->get;

# DESCRIPTION

Net::Async::MPD provides a non-blocking interface to an MPD server.

# ATTRIBUTES

- **host**

    The host to connect to. Defaults to **localhost**.

- **port**

    The port to connect to. Defaults to **6600**.

- **password**

    The password to use to connect to the server. Defaults to undefined, which
    means to use no password.

- **auto\_connect**

    If set to true, the constructor will block until the connection to the MPD
    server has been established. Defaults to false.

# METHODS

- **connect**

    If the client is not connected, wait until it is. Otherwise, do nothing.
    Returns the client itself.

- **send** $cmd
- **send** $cmd => @args
- **send** \[ $cmd1 $cmd2 $cmd3 \]

    Send a command to the server in a non-blocking way. This method always returns
    a [Future](https://metacpan.org/pod/Future).

    If called with a single string, then that string will be sent as the command.

    If called with a list, the list will be joined with spaces and sent as the
    command.

    If called with an array reference, then the value of each of item in that array
    will be processed as above (with array references instead of plain lists). If
    the referenced array contains more than one command, then these will be sent to
    the server as a command list.

    An optional subroutine reference passed as the last argument will be set as the
    the `on_ready` of the Future, which will fire when there is a response from
    the server.

    The response from the server will be parsed with a command-specific parser, to
    provide some structure to the flat lists returned by MPD. If no parser is
    found, or if the user specifically asks for no parser to be used (see below),
    then the response will be an array reference with the raw lines from the server.

    Finally, a hash reference with additional options can be passed as the _first_
    argument. Valid keys to use are:

    - **parser**

        Specify the parser to use for the response. Parser labels are MPD commands. If
        the requested parser is not found, the fallback `none` will be used.

        Alternatively, if the value itself is a code reference, then that will be
        called with a reference to the raw list of lines as its only argument.

    For ease of use, underscores in the final command name will be removed before
    sending to the server (unless the command name requires them).

- **get**

    Send a command in a blocking way. Internally calls **send** and immediately
    waits for the response.

- **idle**

    Put the client in idle loop. This sends the `idle` command and registers an
    internal listener that will put the client back in idle mode after each server
    response.

    If called with a list of subsystem names, then the client will only listen to
    those subsystems. Otherwise, it will listen to all of them.

    If you are using this module for an event-based application (see below), this
    will configure the client to fire the events at the appropriate times.

    Returns a [Future](https://metacpan.org/pod/Future). Waiting on this future will block until the next call to
    **noidle** (see below).

- **noidle**

    Cancel the client's idle mode. Sends an undefined value to the future created
    by **idle** and breaks the internal idle loop.

- **version**

    Returns the version number of the protocol spoken by the server, and _not_ the
    version of the daemon.

    As this is provided by the server, this is `undef` until after a connection
    has been established with the `connect` method, or by setting `auto_connect`
    to true in the constructor.

# EVENTS

[Net::Async::MPD](https://metacpan.org/pod/Net::Async::MPD) does the [Role::EventEmitter](https://metacpan.org/pod/Role::EventEmitter) role, and inherits all the
methods defined therein. Please refer to that module's documentation for
information on how to register subscribers to the different events.

## Additional methods

- **until**

    In addition to methods like `on` and `once`, provided by
    [Role::EventEmitter](https://metacpan.org/pod/Role::EventEmitter),this module also exposes an `until` method, which
    registers a listener until a certain condition is true, and then deregisters it.

    The method is called with two subroutine references. The first is unsubscribed
    as a regular listener, and the second is called only then the first one returns
    a true value. At that point, the entire set is unsubscribed.

## Event descriptions

After calling **idle**, the client will be in idle mode, which means that any
changes to the specified subsystemswill trigger a signal. When the client
receives this signal, it will fire an event named as the subsystem that fired
it.

The event will be fired with the client as the first argument, and the response
from the server as the second argument. This can safely be ignored, since the
server response will normally just hold the name of the subsystem that changed,
which you already know.

The existing events are the following, as defined by the MPD documentation.

- **database**

    The song database has been changed after **update**.

- **udpate**

    A database update has started or finished. If the database was modified during
    the update, the **database** event is also emitted.

- **stored\_playlist**

    A stored playlist has been modified, renamed, created or deleted.

- **playlist**

    The current playlist has been modified.

- **player**

    The player has been started stopped or seeked.

- **mixer**

    The volume has been changed.

- **output**

    An audio output has been added, removed or modified (e.g. renamed, enabled or
    disabled)

- **options**

    Options like repeat, random, crossfade, replay gain.

- **partition**

    A partition was added, removed or changed.

- **sticker**

    The sticket database has been modified.

- **subscription**

    A client has subscribed or unsubscribed from a channel.

- **message**

    A message was received on a channel this client is subscribed to.

- **close**

    The connection to the server has been closed. This event is not part of the
    MPD protocol, and is fired by [Net::Async::MPD](https://metacpan.org/pod/Net::Async::MPD) directly.

- **error**

    The `error` event is inherited from [Role::EventEmitter](https://metacpan.org/pod/Role::EventEmitter). Reer to that
    module's documentation for more information.

# SEE ALSO

- [Net::MPD](https://metacpan.org/pod/Net::MPD)

    A lightweight blocking MPD library. Has fewer dependencies than this one, but
    it does not curently support command lists. I took the idea of allowing for
    underscores in command names from this module.

- [AnyEvent::Net::MPD](https://metacpan.org/pod/AnyEvent::Net::MPD)

    The original version of this module, which used [AnyEvent](https://metacpan.org/pod/AnyEvent). The interface on
    both of these modules is virtually identical.

- [Audio::MPD](https://metacpan.org/pod/Audio::MPD)

    The first MPD library on CPAN. This one also blocks and is based on [Moose](https://metacpan.org/pod/Moose).
    However, it seems to be unmaintained at the moment.

- [Dancer::Plugin::MPD](https://metacpan.org/pod/Dancer::Plugin::MPD)

    A [Dancer](https://metacpan.org/pod/Dancer) plugin to connect to MPD. Haven't really tried it, since I
    haven't used Dancer...

- [POE::Component::Client::MPD](https://metacpan.org/pod/POE::Component::Client::MPD)

    A [POE](https://metacpan.org/pod/POE) component to connect to MPD. This uses Audio::MPD in the background.

# AUTHOR

- José Joaquín Atria <jjatria@cpan.org>

# COPYRIGHT AND LICENSE

This software is copyright (c) 2017 by José Joaquín Atria.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.
