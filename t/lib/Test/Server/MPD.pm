use strict;
use warnings;

package Test::Server::MPD;

our $VERSION = '1.120990';

# ABSTRACT: automate launching of fake mdp for testing purposes

use Moo;

use IO::Async::Loop;
use File::Share qw( dist_file );
use File::Which qw( which );
use Path::Tiny qw( path );
use Types::Path::Tiny qw( File Dir );
use Types::Standard qw( Str Int HashRef ArrayRef Undef );
use Net::EmptyPort qw( empty_port check_port );

has port => (
  is => 'ro',
  isa => Int,
  lazy => 1,
  default => sub {
    my $port = $ENV{MPD_PORT} // 6600;
    check_port($port) ? empty_port() : $port;
  },
);

has host => (
  is => 'ro',
  isa => Str,
  lazy => 1,
  default => 'localhost',
);

has template => (
  is => 'rw',
  lazy => 1,
  isa => File,
  coerce => 1,
  default => sub { path( dist_file('Net-Async-MPD', 'mpd.conf.template') ) },
);

has profiles => (
  is => 'rw',
  isa => HashRef[ArrayRef],
  lazy => 1,
  default => sub { {} }
);

has root => (
  is => 'ro',
  lazy => 1,
  isa => Dir,
  coerce => 1,
  default => sub { Path::Tiny::tempdir() }
);

has config => (
  is => 'ro',
  lazy => 1,
  isa => File,
  coerce => 1,
  default => sub { $_[0]->_populate_config }
);

has bin => (
  is => 'ro',
  lazy => 1,
  isa => File,
  coerce => 1,
  default => sub {
    which 'mpd'
      or die 'Could not find MPD executable in PATH. Try setting it manually', "\n";
  }
);

has _pid => (
  is => 'rw',
  isa => Int|Undef,
);

use DDP;

sub BUILD {
  my ($self) = @_;

  $self->root->child('playlists')->mkpath;
  $self->root->child('music')->mkpath;
}

sub _populate_config {
  my ($self) = @_;

  my $template = $self->template->slurp;

  foreach my $method (qw( port root )) {
    my $value = $self->$method;
    $template =~ s/\{\{ $method \}\}/$value/g;
  }

  my $host = $self->host;
  $template =~ s/\{\{ host \}\}/$host/g;

  my $profiles = q{};
  foreach my $password (keys %{$self->profiles}) {
    my @permissions = @{$self->profiles->{$password}};
    $profiles .= qq{password\t"$password\@} . join(',', @permissions) . qq{"\n}
  }
  $template =~ s/\{\{ profiles \}\}\s*\n/$profiles/g;

  my $config = $self->root->child('mpd.conf');
  $config->spew($template);

  return $config;
}

sub is_running { defined $_[0]->_pid }

sub start {
  my ($self) = @_;

  my $loop = IO::Async::Loop->new;
  my $start = $loop->new_future;

  my ( $in, $out ) = IO::Async::OS->pipepair;
  $self->_pid(
    $loop->run_child(
      command => [ $self->bin, $self->config->realpath ],
      on_finish => sub {
        my ($pid, $exitcode, $stdout, $stderr) = @_;
        return $start->fail('Could not start MPD server: ' . $stdout)
          if $exitcode != 0;

        $start->done;
      },
    )
  );

  $start->get;
  return $self->_pid;
}

sub stop {
  my ($self) = @_;

  return unless $self->is_running;

  my $loop = IO::Async::Loop->new;
  my $stop = $loop->new_future;

  $loop->run_child(
    command => [ $self->bin, '--kill', $self->config->realpath ],
    on_finish => sub {
      my ($pid, $exitcode, $stdout, $stderr) = @_;

      return $stop->fail('Could not stop MPD server: ' . $stdout)
        if $exitcode != 0;

      $self->_pid(undef);
      $stop->done;
    },
  );

  return $stop->get;
}

1;

# =pod
#
# =head1 NAME
#
# Test::Corpus::Audio::MPD - automate launching of fake mdp for testing purposes
#
# =head1 VERSION
#
# version 1.120990
#
# =head1 SYNOPSIS
#
#     use Test::Corpus::Audio::MPD; # die if error
#     [...]
#     stop_test_mpd();
#
# =head1 DESCRIPTION
#
# This module will try to launch a new mpd server for testing purposes.
# This mpd server will then be used during L<POE::Component::Client::MPD>
# or L<Audio::MPD> tests.
#
# In order to achieve this, the module will create a fake F<mpd.conf> file
# with the correct pathes (ie, where you untarred the module tarball). It
# will then check if some mpd server is already running, and stop it if
# the C<MPD_TEST_OVERRIDE> environment variable is true (die otherwise).
# Last it will run the test mpd with its newly created configuration file.
#
# Everything described above is done automatically when the module
# is C<use>-d.
#
# Once the tests are run, the mpd server will be shut down, and the
# original one will be relaunched (if there was one).
#
# Note that the test mpd will listen to C<localhost>, so you are on the
# safe side. Note also that the test suite comes with its own ogg files.
# Those files are 2 seconds tracks recording my voice saying ok, and are
# freely redistributable under the same license as the code itself.
#
# In case you want more control on the test mpd server, you can use the
# supplied public methods. This might be useful when trying to test
# connections with mpd server.
#
# =head1 METHODS
#
# =head2 customize_test_mpd_configuration( [$port] );
#
# Create a fake mpd configuration file, based on the file
# F<mpd.conf.template> located in F<share> subdir. The string PWD will be
# replaced by the real path (ie, where the tarball has been untarred),
# while TMP will be replaced by a new temp directory. The string PORT will
# be replaced by C<$port> if specified, 6600 otherwise (MPD's default).
#
# =head2 my $dir = playlist_dir();
#
# Return the temp dir where the test playlists will be stored.
#
# =head2 start_test_mpd();
#
# Start the fake mpd, and die if there were any error.
#
# =head2 stop_test_mpd();
#
# Kill the fake mpd.
#
# =head1 SEE ALSO
#
# You can look for information on this module at:
#
# =over 4
#
# =item * Search CPAN
#
# L<http://search.cpan.org/dist/Test-Corpus-Audio-MPD>
#
# =item * See open / report bugs
#
# L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Test-Corpus-Audio-MPD>
#
# =item * Mailing-list (same as L<Audio::MPD>)
#
# L<http://groups.google.com/group/audio-mpd>
#
# =item * Git repository
#
# L<http://github.com/jquelin/test-corpus-audio-mpd>
#
# =item * AnnoCPAN: Annotated CPAN documentation
#
# L<http://annocpan.org/dist/Test-Corpus-Audio-MPD>
#
# =item * CPAN Ratings
#
# L<http://cpanratings.perl.org/d/Test-Corpus-Audio-MPD>
#
# =back
#
# =head1 AUTHOR
#
# Jerome Quelin
#
# =head1 COPYRIGHT AND LICENSE
#
# This software is copyright (c) 2009 by Jerome Quelin.
#
# This is free software; you can redistribute it and/or modify it under
# the same terms as the Perl 5 programming language system itself.
#
# =cut
#
#
# __END__
#
