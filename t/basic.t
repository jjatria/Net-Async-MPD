use Test::More;
use Test::Warnings;

use Net::MPD::Emitter;

ok my $mpd = Net::MPD::Emitter->new, 'constructor succeeds';

done_testing();
