package MT::Plugin::Fastly::Worker::PurgeBySurrogateKey;

use strict;
use base qw( TheSchwartz::Worker );

use TheSchwartz::Job;
use MT::Plugin::Fastly;

sub max_retries {10}
sub retry_delay {1}

sub work {
    my $class = shift;
    my TheSchwartz::Job $job = shift;

    my $blog = MT->model('blog')->load($job->uniqkey)
        or return;
    MT::Plugin::Fastly::purge_by_surrogate_key($blog);

    $job->completed();
}

1;
