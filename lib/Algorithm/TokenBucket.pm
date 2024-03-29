package Algorithm::TokenBucket;

use 5.006;

our $VERSION = 0.36;

use warnings;
use strict;

BEGIN {
    eval { require Time::HiRes; import Time::HiRes 'time' } # use if available
}

=head1 NAME

Algorithm::TokenBucket - Token bucket rate limiting algorithm

=head1 SYNOPSIS
    
    use Algorithm::TokenBucket;

    # configure a bucket to limit a stream up to 100 items per hour
    # with bursts of 5 items max
    my $bucket = new Algorithm::TokenBucket 100 / 3600, 5;

    # wait till we're allowed to process 3 items
    until ($bucket->conform(3)) {
        sleep 0.1;
        # do things
    }
    
    # process 3 items because we now can
    process(3);

    # leak (flush) bucket
    $bucket->count(3);  # or, e.g. $bucket->count(1) for 1..3;

    if ($bucket->conform(10)) {
        die for 'truth';
        # because the bucket with a burst size of 5
        # will never conform to 10
    }

    my $time = Time::HiRes::time;
    while (Time::HiRes::time - $time < 7200) {  # two hours
        # be bursty
        if ($bucket->conform(5)) {
            process(5);
            $bucket->count(5);
        }
    }
    # we're likely to have processed 200 items (and hogged CPU, btw)

    Storable::store $bucket, 'bucket.stored';
    my $bucket1 = new Algorithm::TokenBucket
            @{Storable::retrieve('bucket.stored')};

=head1 DESCRIPTION

Token bucket algorithm is a flexible way of imposing a rate limit
against a stream of items. It is also very easy to combine several
rate-limiters in an C<AND> or C<OR> fashion.

Each bucket has a memory footprint of constant size because the
algorithm is based on C<information rate>. This was my main motivation to
implement it. Other rate limiters on CPAN keep track of I<ALL> incoming
items in memory. It allows them to be precisely accurate.

FYI, C<conform>, C<count>, C<information rate>, C<burst size> terms are
shamelessly borrowed from http://linux-ip.net/gl/tcng/node62.html
page.

=head1 INTERFACE

=cut

use fields qw/info_rate burst_size _tokens _last_check_time/;

=head2 METHODS

=over 4

=item new($$;$$)

The constructor takes as parameters at least C<rate of information> in
items per second and C<burst size> in items. It can also take current
token counter and last check time but this usage is reserved for
restoring a saved bucket, beware. See L</state>.

=cut

sub new {
    my $class   = shift;
    fields::new($class)->_init(@_);
}

sub _init {
    my Algorithm::TokenBucket $self = shift;

    @$self{qw/info_rate burst_size _tokens _last_check_time/} = @_;
    $self->{_last_check_time} ||= time;
    $self->{_tokens} ||= 0;

    return $self;
}

=item state()

This method returns the state of the bucket as a list. Use it for storing purposes.
Buckets also natively support freezing and thawing with L<Storable> by
providing STORABLE_* callbacks.

=cut

sub state {
    my Algorithm::TokenBucket $self = shift;

    return @$self{qw/info_rate burst_size _tokens _last_check_time/};
}

use constant PACK_FORMAT => "d4";   # "F4" is not 5.6 compatible

sub STORABLE_freeze {
    my ( $self, $cloning ) = @_;
    return pack(PACK_FORMAT(),$self->state);
}

sub STORABLE_thaw {
    my ( $self, $cloning, $state ) = @_;
    return $self->_init(unpack(PACK_FORMAT(),$state));
}

sub _token_flow {
    my Algorithm::TokenBucket $self = shift;

    my $time = time;

    $self->{_tokens}        += ($time - $self->{_last_check_time}) * $self->{info_rate};
    $self->{_tokens} > $self->{burst_size} and $self->{_tokens} = $self->{burst_size};

    $self->{_last_check_time}= $time;
}

=item conform($)

This sub checks if the bucket contains at least I<N> tokens. In that
case it is allowed to transmit (or process) I<N> items (not
exactly right because I<N> can be fractional) from the stream. A bucket never
conforms to an I<N> greater than C<burst size>.

It returns a boolean value.

=cut

sub conform {
    my Algorithm::TokenBucket $self = shift;
    my $size = shift;

    $self->_token_flow;

    return $self->{_tokens} >= $size;
}

=item count($)

This sub removes I<N> (or all if there are less than I<N> available) tokens from the bucket.
Does not return a meaningful value.

=cut

sub count {
    my Algorithm::TokenBucket $self = shift;
    my $size = shift;

    $self->_token_flow;

    ($self->{_tokens} -= $size) < 0 and $self->{_tokens} = 0;
}

=item until($)

This sub returns the number of seconds until I<N> tokens can be removed from the bucket.
It's especially useful in multitasking environments like L<POE> where you
cannot busy-wait. One can safely schedule the next conform($N) check in until($N)
seconds instead of checking repeatedly.

Note that until() does not take into account C<burst size>. That means
a bucket will not conform to I<N> even after sleeping for until($N)
seconds if I<N> is greater than C<burst size>.

=cut

sub until {
    my Algorithm::TokenBucket $self = shift;
    my $size = shift;

    $self->_token_flow;

    if ( $self->{_tokens} >= $size ) {
        # can conform() right now
        return 0;
    } else {
        my $needed = $size - $self->{_tokens};
        return ( $needed / $self->{info_rate} );
    }
}

=item get_token_count()

Returns the current number of tokens in the bucket. This method may be
useful for inspection or debugging purposes. You should not examine
the state of the bucket for rate limiting purposes.

This number will frequently be fractional so it's not exactly a
"count".

=cut

sub get_token_count {
    my Algorithm::TokenBucket $self = shift;
    $self->_token_flow;
    return $self->{_tokens};
}

1;
__END__

=back

=head1 EXAMPLES

Think a rate limiter for a mail sending application. We'd like to
allow 2 mails per minute but no more than 20 mails per hour.
Go, go, go!

    my $rl1 = new Algorithm::TokenBucket 2/60, 1;
    my $rl2 = new Algorithm::TokenBucket 20/3600, 10;
        # "bursts" of 10 to ease the lag but $rl1 enforces
        # 2 per minute, so it won't flood

    while (my $mail = get_next_mail) {
        until ($rl1->conform(1) && $rl2->conform(1)) {
            busy_wait;
        }

        $mail->take_off;
        $rl1->count(1); $rl2->count(1);
    }

Now, let's fix the CPU-hogging example from L</SYNOPSIS> using
L</until()> method.

    my $bucket = new Algorithm::TokenBucket 100 / 3600, 5;
    my $time = Time::HiRes::time;
    while (Time::HiRes::time - $time < 7200) {  # two hours
        # be bursty
        Time::HiRes::sleep $bucket->until(5);
        if ($bucket->conform(5)) {  # should always be true
            process(5);
            $bucket->count(5);
        }
    }
    # we're likely to have processed 200 items (without hogging the CPU)

=head1 BUGS

Works unreliably for fractional rates unless Time::HiRes is present.

Documentation lacks the actual algorithm description. See links or read
the source (there are about 20 lines of sparse perl in several subs, trust me).

until($N) does not return infinity if $N is greater than C<burst
size>. Sleeping for infinity seconds is both useless and hard to
debug.

=head1 ACKNOWLEDGMENTS

Yuval Kogman contributed the L</until> method, proper L<Storable> support
and other things.

Alexey Shrub contributed the L</get_token_count> method.

=head1 COPYRIGHT AND LICENSE

This software is copyright (C) 2012 by Alex Kapranoff.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=head1 AUTHOR

Alex Kapranoff, E<lt>kappa@cpan.orgE<gt>

=head1 SEE ALSO

http://www.eecs.harvard.edu/cs143/assignments/pa1/,
http://en.wikipedia.org/wiki/Token_bucket, 
http://linux-ip.net/gl/tcng/node54.html,
http://linux-ip.net/gl/tcng/node62.html,
L<Schedule::RateLimit>, L<Algorithm::FloodControl>.

=cut
