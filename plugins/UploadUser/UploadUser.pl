package MT::Plugin::UploadUser;
use strict;
use MT;
use MT::Plugin;
use MT::Author;

use MT::Util qw( offset_time_list );
use File::Temp qw( tempfile );

our $VERSION = '0.1';

use base qw( MT::Plugin );

@MT::Plugin::UploadUser::ISA = qw( MT::Plugin );

my $plugin = new MT::Plugin::UploadUser ( {
    id =>   'UploadUser',
    key =>  'uploaduser',
    name => 'UploadUser',
    description => '<MT_TRANS phrase=\'_PLUGIN_DESCRIPTION\'>',
    author_name => 'Alfasado, Inc.',
    author_link => 'http://alfasado.net/',
    version => $VERSION,
    l10n_class => 'UploadUser::L10N',
} );

MT->add_plugin( $plugin );

sub init_registry {
    my $plugin = shift;
    $plugin->registry( {
        applications => {
            cms => {
                methods => {
                    upload_user => 'MT::Plugin::UploadUser::_upload_user',
                    download_user => 'MT::Plugin::UploadUser::_download_user',
                },
            },
        },
        callbacks => {
            'MT::App::CMS::template_source.list_author'
                 => \&_cb_ts_list_author,
        },
    } );
}

sub _cb_ts_list_author {
    my ( $cb, $app, $tmpl ) = @_;
    my $insert = &_tmpl();
    my $magic_token = 'magic_token=' . $app->current_magic;
    $insert =~ s/magic_token=/$magic_token/;
    if ( MT->version_number >= 5 ) {
        $insert = '<ul>' . $insert . '</li></ul>';
        $$tmpl =~ s/(<div\sclass="listing\-filter">)/$insert$1/sg;
    }else{
        $$tmpl =~ s/(<ul\sclass="action\-link\-list">.*?<\/li>).*?(<\/ul>)/$1$insert$2/sg;
    }
}

sub _download_user {
    my $app = shift;
    my $user  = $app->user;
    my $admin = $user->is_superuser;
    if (! $admin ) {
        return $app->trans_error( 'Permission denied.' );
    }
    $app->validate_magic or return $app->trans_error( 'Permission denied.' );
    my $iter = MT::Author->load_iter( undef );
    my $csv = do {
        eval { require Text::CSV_XS };
        unless ( $@ ){
            Text::CSV_XS->new ( { binary => 1 } );
        }else{
            eval { require Text::CSV };
            die "Neither Text::CSV_XS nor Text::CSV is available" if $@;
            Text::CSV->new ( { binary => 1 } );
        }
    };
    $app->{ no_print_body } = 1;
    my @tl = offset_time_list( time, undef );
    my $ts = sprintf "%04d%02d%02d%02d%02d%02d", $tl[5]+1900, $tl[4]+1, @tl[3,2,1,0];
    $app->set_header( "Content-Disposition" => "attachment; filename=csv_$ts.csv" );
    $app->send_http_header( 'text/csv' );
    my $publishcharset = $app->config( 'PublishCharset' );
    use Encode::Guess qw/ utf8 euc-jp shiftjis 7bit-jis /;
    use Encode qw( encode decode );
    require MT::Role;
    require MT::Association;
    while ( my $author = $iter->() ) {
        my @fields = ();
        push ( @fields, $author->name );
        push ( @fields, $author->nickname );
        push ( @fields, $author->email );
        push ( @fields, $author->preferred_language );
        push ( @fields, $author->status );
        push ( @fields, '' );
        # my @role = MT::Role->load( undef, { join => MT::Association->join_on( 
        #                               'author_id', { author_id  => $author->id }, { limit => 5 } ) } ) ;
        my @assoc = MT::Association->load( { author_id  => $author->id, type => 1 } );
        for my $association ( @assoc ) {
            my $role = MT::Role->load( $association->role_id );
            if ( $role ) {
                my $str = $association->blog_id . '_' . $role->name;
                push ( @fields, $str );
            }
        }
        if ( $csv->combine( @fields ) ) {
            my $string = $csv->string;
            if ( $publishcharset ne 'Shift_JIS' ) {
                unless ( MT->version_number >= 5 ) {
                    $string = decode( 'utf8', $string );
                }
                $string = encode( 'shiftjis', $string, Encode::FB_HTMLCREF );
            }
            print $string, "\n";
        } else {
            my $err = $csv->error_input;
            print "combine() failed on argument: ", $err, "\n";
        }
    }
}

sub _upload_user {
    my $app = shift;
    my $user  = $app->user;
    my $admin = $user->is_superuser;
    if (! $admin ) {
        return $app->trans_error( 'Permission denied.' );
    }
    $app->validate_magic or return $app->trans_error( 'Permission denied.' );
    my $q = $app->param;
    my $upload = $q->upload( 'csvfile' );
    my $tmp_dir = $app->config( 'TempDir' );
    $tmp_dir = $app->config( 'TmpDir' ) unless $tmp_dir;
    my ( $tmp_fh, $tmp_filename ) = tempfile( DIR => $tmp_dir );
    while ( read ( $upload, my $buffer, 2048 ) ){
        $buffer =~ s/\r\n/\n/g;
        $buffer =~ s/\r/\n/g;
        print $tmp_fh $buffer;
    }
    close $tmp_fh;
    local *IN;
    open IN, $tmp_filename;
    my @list = <IN>;
    close IN;
    my @tl = offset_time_list( time, undef );
    my $ts = sprintf "%04d%02d%02d%02d%02d%02d", $tl[5]+1900, $tl[4]+1, @tl[3,2,1,0];
    my $encoding;
    my $publishcharset = $app->config( 'PublishCharset' );
    if ( $publishcharset eq 'UTF-8' ) {
        $encoding = 'utf8';
    } elsif ( $publishcharset eq 'EUC-JP' ) {
        $encoding = 'euc';
    }
    my $tc = do{
        eval { require Text::CSV_XS };
        unless ( $@ ){
            Text::CSV_XS->new ( { binary => 1 } );
        } else {
            eval { require Text::CSV };
            die "Neither Text::CSV_XS nor Text::CSV is available" if $@;
            Text::CSV->new ( { binary => 1 } );
        }
    };
    my @blogs = MT::Blog->load();
    for my $line ( @list ) {
        chomp $line;
        if ( $publishcharset ne 'SHIFT_JIS' ) {
            $line = MT::I18N::encode_text( $line, 'sjis', $encoding );
        }
        next unless $tc->parse( $line );
        my @clumns = $tc->fields;
        my $count = scalar @clumns;
        $count--;
        my $name = $clumns[0]; # name
        next unless $name;
        my $obj = MT::Author->get_by_key( { name => $name } );
        my $nickname = $clumns[1]; # nickname
        my $email = $clumns[2];
        # my $mobile_address = $clumns[3];
        # my $mail_token = $clumns[4];
        my $preferred_language = $clumns[3];
        my $status = $clumns[4];
        my $password = $clumns[5]; # unless ( $obj->id );
        my @assoc;
        for ( 6 .. $count ) {
            push ( @assoc, $clumns[$_] ) if $clumns[6];
        }
        next if ( (! $nickname ) || (! $email ) || (! $preferred_language ) || (! $status ) );
        # next if ( (! $nickname ) || (! $email ) || (! $mobile_address ) || (! $mail_token ) || (! $preferred_language ) || (! $status ) );
        $obj->set_values( { nickname => $nickname,
                            email => $email,
                            preferred_language => $preferred_language,
                            type => 1,
                            auth_type => 'MT',
                        } );
        # $obj->mobile_address( $mobile_address );
        # $obj->mail_token( $mail_token );
        $obj->set_password( $password ) if $password;
        my $basename = MT::Util::make_unique_author_basename( $obj );
        $obj->basename( $basename );
        $obj->save or die $obj->errstr;
        require MT::Role;
        require MT::Permission;
        for my $association ( @assoc ) {
            next unless $association;
            my @as = split ( /_/, $association );
            my $blog_id;
            if ( scalar @as == 2 ) {
                $blog_id = $as[0];
                $association = $as[1];
            }
            if ( ( $blog_id eq '0' ) && ( $association eq $app->translate( 'System Administrator' ) ) ) {
                my $permission = MT::Permission->get_by_key ( { author_id => $obj->id, blog_id => 0 } );
                $permission->created_on( $ts );
                if ( MT->version_number >= 5 ) {
                    $permission->permissions( "'administer','create_blog','create_website','edit_templates','manage_plugins','view_log'" );
                } else {
                    $permission->permissions( "'administer','create_blog','view_log','manage_plugins','edit_templates'" );
                }
                $permission->save or die $permission->errstr;
            } else {
                my $role = MT::Role->load( { name => $association } );
                if ( $role ) {
                    if ( $blog_id ) {
                        my @target = grep { $_->id == $blog_id } @blogs;
                        my $blog = $target[ 0 ];
                        if ( $blog ) {
                            _association_link( $app, $obj, $role, $blog );
                        }
                    } else {
                        for my $blog ( @blogs ) {
                            _association_link( $app, $obj, $role, $blog );
                        }
                    }
                }
            }
        }
    }
    $app->add_return_arg( saved_changes => 1 );
    $app->call_return;
}

sub _association_link {
    my ( $app, $author, $role, $blog ) = @_;
    require MT::Association;
    require MT::Log;
    MT::Association->link( $author => $role => $blog );
    my $log = MT::Log->new;
    my $msg = { message => $app->translate(
                '[_1] registered to the blog \'[_2]\'',
                $author->name,
                $blog->name
            ),
            level    => MT::Log::INFO(),
            class    => 'author',
            category => 'new',
            blog_id => $blog->id,
            ip => $app->remote_ip,
    };
    $log->set_values( $msg );
    if ( my $user = $app->user ) {
        $log->author_id( $user->id );
    }
    $log->save or die $log->errstr;
    return 1;
}

sub _tmpl {
    return <<'MTML';
        <__trans_section component="UploadUser">
        <li class="icon-left icon-create"><a href="javascript:void(0)" onclick="
        if ( getByID( 'upload' ).style.display == 'none' ) {
            getByID( 'upload' ).style.display = 'inline';
        } else {
            if ( getByID( 'csvfile' ).value == '' ) {
                alert( '<__trans phrase="No file selected.">' );
            } else {
                if ( confirm ( '<__trans phrase="Are you sure you want to upload users?">' ) ) {
                    getByID('upload_csv').submit();
                    return false;
                }
            }
        }
        "><__trans phrase="Upload"></a>
        <form style="display:inline" id="upload_csv" name="upload_csv" action="<$mt:var name="script_url"$>" enctype="multipart/form-data" method="post">
        <span style="display:none" id="upload">
        <input type="file" id="csvfile" name="csvfile" style="font-size:11px;padding:0px"
        onchange="getByID( 'send_csv' ).style.display = 'inline';"
        />
        <input type="hidden" name="__mode" value="upload_user" />
        <input type="hidden" name="return_args" value="__mode=list_user" />
        <input type="hidden" name="magic_token" value="<$mt:var name="magic_token"$>" />
        <a href="javascript:void(0)" style="display:none" id="send_csv" onclick="
        if ( getByID( 'upload' ).style.display == 'none' ) {
            getByID( 'upload' ).style.display = 'inline';
        } else {
            if ( getByID( 'csvfile' ).value == '' ) {
                alert( '<__trans phrase="No file selected.">' );
            } else {
                if ( confirm ( '<__trans phrase="Are you sure you want to upload users?">' ) ) {
                    getByID('upload_csv').submit();
                    return false;
                }
            }
        }
        "><__trans phrase="Send"></a>
        </span>
        </form></li>
        <li class="icon-left icon-create">
        <a href="<$mt:var name="script_url"$>?__mode=download_user&magic_token="><__trans phrase="Download"></a>
        </__trans_section>
MTML
}

1;