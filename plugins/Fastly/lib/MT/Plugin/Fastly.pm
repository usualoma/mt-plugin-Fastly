package MT::Plugin::Fastly;

use strict;
use warnings;
use utf8;

use MT::Util;
use HTTP::Request;

sub translate {
    MT->component('Fastly')->translate(shift);
}

sub enabled {
    my ($blog) = @_;
    MT->component('Fastly')->get_config_value('fastly_enabled', 'blog:' . $blog->id);
}

sub cname {
    my ($blog) = @_;
    MT->component('Fastly')->get_config_value('fastly_cname', 'blog:' . $blog->id);
}

sub cache_server_uris {
    my ($blog) = @_;
    [map {
        my $uri = URI->new($_ =~ m/:/ ? $_ : "http://$_");
        $uri->scheme('http') unless $uri->scheme;
        $uri;
    } split(/\s*,\s*/, cname($blog))];
}

sub additional_headers {
    my ($blog) = @_;
    my $text = MT->component('Fastly')->get_config_value('fastly_additional_headers', 'blog:' . $blog->id) || '';
    +{
        map {
            split /\s*:\s*/, $_;
        } split(/\r\n|\r|\n/, $text)
    };
}

sub wait_for_prview {
    my ($blog) = @_;
    MT->component('Fastly')->get_config_value('fastly_wait_for_preview', 'blog:' . $blog->id);
}

sub debug_mode {
    MT->component('Fastly')->get_config_value('fastly_debug_mode');
}

sub send_purge_request {
    my ($host, $url, $headers) = @_;

    my $req = HTTP::Request->new(PURGE => $url);
    $req->header('Host' => $host);
    for my $k (%$headers) {
        $req->header($k => $headers->{$k});
    }

    if (debug_mode()) {
        MT->instance->log("PURGE Host: $host URL: $url");
    }

    my $ua  = MT->new_ua;
    my $res = $ua->request($req);

    unless ($res->is_success) {
        MT->instance->log($res->status_line);
    }
    elsif (debug_mode()) {
        MT->instance->log($res->decoded_content);
    }
}

sub purge {
    my ($blog, $url) = @_;

    my $uri     = URI->new($url);
    my $host    = $uri->host;
    my $headers = additional_headers($blog);

    for my $u (@{cache_server_uris($blog)}) {
        $uri->host($u->host);
        $uri->scheme($u->scheme);

        my $uri_str = $uri->as_string;
        send_purge_request($host, $uri_str, $headers);

        my $stripped_uri_str = MT::Util::strip_index($uri_str, $blog);
        send_purge_request($host, $stripped_uri_str, $headers) if $stripped_uri_str ne $uri_str;
    }
}

sub add {
    my ($blog, $url) = @_;
    my $map = MT->request('FastlyPurgeURLs') || MT->request('FastlyPurgeURLs', {});
    $map->{$url} = {blog => $blog};
}

sub build_file {
    my ($app, %params) = @_;
    my ($blog, $fi) = @params{qw(blog file_info)};

    return 1 unless enabled($blog);

    my $blog_site_url = $blog->site_url;
    $blog_site_url =~ s{/$}{};
    add($blog, $blog_site_url . $fi->url);

    1;
}

sub cms_upload_file {
    my ($app, %params) = @_;
    my ($asset) = @params{qw(asset)};
    my $blog = $asset->blog;

    return 1 unless enabled($blog);

    add($blog, $asset->url);

    my $blog_site_path = $blog->site_path;
    my $blog_site_url  = $blog->site_url;
    for my $f (cached_files($asset)) {
        $f =~ s/\Q$blog_site_path\E/$blog_site_url/;
        add($blog, $f);
    }

    1;
}

sub cached_files {
    my ($asset) = @_;

    my $blog = $asset->blog;
    if ($asset->id && $blog) {
        my $cache_dir = $asset->_make_cache_path;
        if ($cache_dir) {
            require MT::FileMgr;
            my $fmgr = $blog->file_mgr || MT::FileMgr->new('Local');
            if ($fmgr) {
                my $basename = $asset->file_name;
                my $ext      = '.' . $asset->file_ext;
                $basename =~ s/$ext$//;
                my $cache_glob = File::Spec->catfile( $cache_dir,
                    $basename . '-thumb-*-' . $asset->id . $ext );
                return glob($cache_glob);
            }
        }
    }
}

sub post_run {
    my ($cb, $app) = @_;

    my $mode = $app->mode;

    if (
        ($mode eq 'preview_entry' || $mode eq 'preview_template')
        && enabled($app->blog)
    ) {
        add($app->blog, $app->{redirect}) if $app->{redirect};

        my $body = $app->response_content();
        if (ref($body) && $body->isa('MT::Template')) {
            my $preview_url = $body->param->{preview_url};
            add($app->blog, $preview_url) if $preview_url;
        }
    }

    my $map = MT->request('FastlyPurgeURLs');
    if ($map) {
        for my $url (keys %$map) {
            purge($map->{$url}{blog}, $url);
        }
    }


    if (
        ($mode eq 'preview_entry' || $mode eq 'preview_template')
        && enabled($app->blog)
    ) {
        sleep(wait_for_prview());
    }

    1;
}

sub template_source_cfg_prefs {
    my ($cb, $app, $tmpl) = @_;
    my $label = translate('Edge Side Includes');
    $$tmpl =~ s{(id="include_system".*?)(</select>)}{$1<option value="esi"<mt:if name="include_system" eq="esi"> selected="selected"</mt:if>>$label</option>$2}sm;
}

sub init_app {
    require MT::Blog;

    {
        no warnings 'redefine';
        my $orig = \&MT::Blog::include_statement;
        *MT::Blog::include_statement = sub {
            include_statement($orig, @_);
        };
    }
}

sub include_statement {
    my $orig = shift;
    my $blog = shift;

    my $system = $blog->include_system
        or return;
    return $orig->($blog, @_) if $system ne 'esi';

    my ($filename, @path) = $blog->include_path_parts(@_);
    my $site_url = $blog->site_url;
    $site_url =~ s{ / \z }{}xms;

    add($blog, join(q{/}, $site_url, @path, $filename));

    $site_url =~ s{ \A \w+ :// [^/]+ }{}xms;
    my $include = join q{/}, $site_url, @path, $filename;

    sprintf qq{<esi:include src="%s"/>}, MT::Util::encode_php($include, q{qq});
}

1;
