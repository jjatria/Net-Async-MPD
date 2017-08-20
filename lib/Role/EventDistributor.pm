package Role::EventDistributor;

use Event::Distributor;

use Moo::Role;

has _ed_events => (
  is => 'ro',
  default => sub { +{} },
  init_arg => undef,
);

has _ed_emitter => (
  is => 'ro',
  default => sub { Event::Distributor->new },
  init_arg => undef,
);

sub on {
  my ($self, $name, $cb) = @_;
  $self->_ed_emitter->subscribe_async( $name, $cb );
  return $cb;
}

sub emit {
  my ($self, $name, @args) = @_;
  $self->_add_event($name) unless $self->_ed_events->{$name};
  return $self->_ed_emitter->fire_async( $name, @args );
}

sub subscribers { shift->_ed_emitter->{events}{shift()}{subscribers} ||= [] }

sub unsubscribe {
  my ($self, $name, $cb) = @_;
  my $subscribers = $self->subscribers($name);

  # One
  if ($cb) {
    $subscribers = [grep { $cb ne $_ } @{$subscribers}];
  }

  # All
  else { $subscribers = [] }

  return $self;
}

sub has_subscribers { !!shift->_ed_emitter->{events}{shift()}{subscribers} }

sub once {
  my ($self, $name, $cb) = @_;

  weaken $self;
  my $wrapper;
  $wrapper = sub {
    $self->unsubscribe($name => $wrapper);
    $cb->(@_);
  };
  $self->on($name => $wrapper);
  weaken $wrapper;

  return $wrapper;
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
  weaken $wrapper;

  return $wrapper;
}

sub catch { $_[0]->on(error => $_[1]) and return $_[0] }

sub _add_event {
  my ($self, $name) = @_;
  $self->_ed_emitter->declare_signal($name);
  $self->_ed_events->{$name} = 1;
  return;
}

1;

=head2 Additional methods

=over 4

=item B<until>

In addition to methods like C<on> and C<once>, copied from
L<Role::EventEmitter>, this module also exposes an C<until> method, which
registers a listener until a certain condition is true, and then deregisters it.

The method is called with two subroutine references. The first is unsubscribed
as a regular listener, and the second is called only then the first one returns
a true value. At that point, the entire set is unsubscribed.

=back
