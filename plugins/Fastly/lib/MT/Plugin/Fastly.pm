package MT::Plugin::Fastly;

use strict;
use warnings;
use utf8;

use MT::Util;
use HTTP::Request;

use constant SURROGATE_KEY => 'mt-plugin-Fastly-dynamic';

sub plugin {
    MT->component('Fastly');
}

sub translate {
    plugin()->translate(shift);
}

sub enabled {
    my ($blog) = @_;
    plugin()->get_config_value('fastly_enabled', 'blog:' . $blog->id);
}

sub cname {
    my ($blog) = @_;
    plugin()->get_config_value('fastly_cname', 'blog:' . $blog->id);
}

sub cache_server_uris {
    my ($blog) = @_;
    [map {
        my $uri = URI->new($_ =~ m/:/ ? $_ : "http://$_");
        $uri->scheme('http') unless $uri->scheme;
        $uri;
    } split(/\s*,\s*/, cname($blog))];
}

sub surrogate_keys {
    my ($blog) = @_;
    my $keys_str = plugin()->get_config_value('fastly_surrogate_keys', 'blog:' . $blog->id);

    [ grep { $_ } split(/\s+/sm, $keys_str) ];
}

sub async_purge_surrogate_keys {
    my ($blog) = @_;
    plugin()->get_config_value('fastly_async_purge_surrogate_keys', 'blog:' . $blog->id);
}

sub service_id {
    my ($blog) = @_;
    plugin()->get_config_value('fastly_service_id', 'blog:' . $blog->id);
}

sub additional_headers {
    my ($blog) = @_;
    my $text = plugin()->get_config_value('fastly_additional_headers', 'blog:' . $blog->id) || '';
    +{
        map {
            split /\s*:\s*/, $_;
        } split(/\r\n|\r|\n/, $text)
    };
}

sub wait_for_prview {
    my ($blog) = @_;
    plugin()->get_config_value('fastly_wait_for_preview', 'blog:' . $blog->id);
}

sub debug_mode {
    plugin()->get_config_value('fastly_debug_mode');
}

sub error_log {
    my ($blog, $message) = @_;

    MT->instance->log({
        blog_id => $blog->id,
        message => $message,
        level   => MT->model('log')->ERROR,
    });
}

sub debug_log {
    my ($blog, $message) = @_;

    MT->instance->log({
        blog_id => $blog->id,
        message => $message,
        level   => MT->model('log')->DEBUG,
    });
}

sub send_instant_purge_request {
    my ($blog, $host, $url) = @_;

    my $req = HTTP::Request->new(PURGE => $url);
    $req->header('Host' => $host);

    my $headers = additional_headers($blog);
    for my $k (%$headers) {
        $req->header($k => $headers->{$k});
    }

    if (debug_mode()) {
        debug_log($blog, "PURGE Host: $host URL: $url");
    }

    my $ua  = MT->new_ua;
    my $res = $ua->request($req);

    unless ($res->is_success) {
        error_log($blog, $res->status_line);
    }
    elsif (debug_mode()) {
        debug_log($blog, $res->decoded_content);
    }
}

sub instant_purge {
    my ($blog, $url) = @_;

    my $uri     = URI->new($url);
    my $host    = $uri->host;

    for my $u (@{cache_server_uris($blog)}) {
        $uri->host($u->host);
        $uri->scheme($u->scheme);

        my $uri_str = $uri->as_string;
        send_instant_purge_request($blog, $host, $uri_str);

        my $stripped_uri_str = MT::Util::strip_index($uri_str, $blog);
        send_instant_purge_request($blog, $host, $stripped_uri_str) if $stripped_uri_str ne $uri_str;
    }
}

sub send_purge_by_surrogate_key_request {
    my ($blog, $surrogate_key) = @_;

    my $service_id = service_id($blog)
        or return 1;
    my $api_key = MT->config->FastlyAPIKey
        or return 1;

    my $req = HTTP::Request->new(
        POST => "https://api.fastly.com/service/$service_id/purge/$surrogate_key"
    );
    $req->header('Fastly-Key' => $api_key);

    if (debug_mode()) {
        debug_log($blog, 'PURGE Surrogate Key: ' . $surrogate_key);
    }

    my $ua  = MT->new_ua;
    my $res = $ua->request($req);

    unless ($res->is_success) {
        error_log($blog, $res->status_line);
    }
    elsif (debug_mode()) {
        debug_log($blog, $res->decoded_content);
    }
}

sub purge_by_surrogate_key {
    my ($blog) = @_;

    for my $k (@{surrogate_keys($blog)}) {
        send_purge_by_surrogate_key_request($blog, $k);
    }
}

sub add_url {
    my ($blog, $url) = @_;

    if (ref(MT->instance) eq 'MT') {
        instant_purge($blog, $url);
        return;
    }

    my $map = MT->request('FastlyPurgeURLs') || MT->request('FastlyPurgeURLs', {});
    $map->{$url} = {blog => $blog};
}

sub add_blog {
    my ($blog) = @_;

    if (ref(MT->instance) eq 'MT') {
        purge_by_surrogate_key($blog);
        return;
    }

    my $map = MT->request('FastlyPurgeBlogs') || MT->request('FastlyPurgeBlogs', {});
    $map->{$blog->id} = {blog => $blog};
}

sub build_file {
    my ($app, %params) = @_;
    my ($blog, $fi) = @params{qw(blog file_info)};

    return 1 unless enabled($blog);

    my $blog_site_url = $blog->site_url;
    $blog_site_url =~ s{/$}{};
    add_url($blog, $blog_site_url . $fi->url);

    1;
}

sub pre_remove_session {
    my ($cb, $ses) = @_;
    my $app = MT->instance
        or return 1;

    return 1 if $ses->kind ne 'TF';

    my $blog = $app->can('blog') && $app->blog
        or return 1;
    my $file = $ses->name;
    $file =~ s/@{[$blog->site_path]}//;
    $file =~ s{ \A /+ }{}xms;

    my $site_url = $blog->site_url;
    $site_url =~ s{ / \z }{}xms;

    add_url($blog, join(q{/}, $site_url, $file));
}

sub pre_remove_fileinfo {
    my ($cb, $fi) = @_;

    require MT::Blog;
    my $blog = MT::Blog->load($fi->blog_id)
        or return 1;

    return 1 unless enabled($blog);

    my $blog_site_url = $blog->site_url;
    $blog_site_url =~ s{/$}{};
    add_url($blog, $blog_site_url . $fi->url);
}

sub permission_filter_asset {
    my ($cb, $app, $asset) = @_;
    add_url_asset($asset);
    1;
}

sub cms_upload_file {
    my ($app, %params) = @_;
    add_url_asset($params{asset});
}

sub add_url_asset {
    my ($asset) = @_;

    my $blog = $asset->blog;

    return 1 unless enabled($blog);

    add_url($blog, $asset->url);

    my $blog_site_path = $blog->site_path;
    my $blog_site_url  = $blog->site_url;
    for my $f (cached_files($asset)) {
        $f =~ s/\Q$blog_site_path\E/$blog_site_url/;
        add_url($blog, $f);
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
        add_url($app->blog, $app->{redirect}) if $app->{redirect};

        my $body = $app->response_content();
        if (ref($body) && $body->isa('MT::Template')) {
            my $preview_url = $body->param->{preview_url};
            add_url($app->blog, $preview_url) if $preview_url;
        }
    }

    my $map = MT->request('FastlyPurgeURLs');
    if ($map) {
        require MT::TheSchwartz;
        require TheSchwartz::Job;

        for my $url (keys %$map) {
            instant_purge($map->{$url}{blog}, $url);
        }
    }

    my $blog_map = MT->request('FastlyPurgeBlogs');
    if ($blog_map) {
        require MT::TheSchwartz;
        require TheSchwartz::Job;

        for my $data (values %$blog_map) {
            if (async_purge_surrogate_keys($data->{blog})) {
                my $job = TheSchwartz::Job->new(
                    funcname => 'MT::Plugin::Fastly::Worker::PurgeBySurrogateKey',
                    uniqkey  => $data->{blog}->id,
                );
                MT::TheSchwartz->insert($job);
            }
            else {
                purge_by_surrogate_key($data->{blog});
            }
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

sub cms_init_app {
    init_app();

    {
        no warnings 'redefine';
        my $app = MT->instance;
        *MT::App::CMS::send_http_header = sub {
            MT::App::send_http_header(@_);
            $app->set_header('Cache-Control' => 'private, no-cache');
        };
        \&MT::App::CMS::send_http_header;
    }
}

sub search_init_app {
    init_app();

    {
        no warnings 'redefine';
        my $app = MT->instance;
        *MT::App::Search::send_http_header = sub {
            MT::App::send_http_header(@_);
            $app->set_header('Surrogate-Key' => SURROGATE_KEY);
        };
        \&MT::App::Search::send_http_header;
    }
}

sub data_api_init_app {
    init_app();

    {
        no warnings 'redefine';
        my $app  = MT->instance;
        my $orig = \&MT::App::DataAPI::send_http_header;
        *MT::App::DataAPI::send_http_header = sub {
            $orig->(@_);

            my $user = $app->authenticate;
            if (
                (lc $app->request_method ne 'get') 
                || ($user && !$user->is_anonymous)
            ) {
                $app->set_header('Cache-Control' => 'private, no-cache');
            }

            $app->set_header('Surrogate-Key' => SURROGATE_KEY);
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

    add_url($blog, join(q{/}, $site_url, @path, $filename));

    $site_url =~ s{ \A \w+ :// [^/]+ }{}xms;
    my $include = join q{/}, $site_url, @path, $filename;

    sprintf qq{<esi:include src="%s"/>}, MT::Util::encode_php($include, q{qq});
}

sub pre_save_object {
    my ($cb, $obj) = @_;

    return 1 if (ref($obj) =~ m/session|::log$|::revision$|touch|fileinfo/i);

    my $blog
        = $obj->isa('MT::Blog') ? $obj
        : $obj->can('blog')     ? $obj->blog
        :                         undef;
    return 1 unless $blog;

    return 1 unless enabled($blog);

    add_blog($blog);
}

1;
