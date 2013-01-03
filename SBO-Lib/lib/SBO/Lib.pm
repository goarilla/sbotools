#!/usr/bin/env perl
#
# vim: set ts=4:noet
#
# Lib.pm
# shared functions for the sbo_ scripts.
#
# authors:	Jacob Pipkin <j@dawnrazor.net>
#			Luke Williams <xocel@iquidus.org>
# license: WTFPL <http://sam.zoy.org/wtfpl/COPYING>

use 5.16.0;
use strict;
use warnings FATAL => 'all';


package SBO::Lib;
our $VERSION = '1.3';

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT = qw(
	script_error
	open_fh
	open_read
	show_version
	slackbuilds_or_fetch
	fetch_tree
	update_tree
	get_installed_sbos
	get_inst_names
	get_available_updates
	get_requires
	get_readme_contents
	do_slackbuild
	make_clean
	make_distclean
	do_upgradepkg
	get_sbo_location
	get_from_info
	get_tmp_extfn
	get_arch
	get_build_queue
	merge_queues
	$tempdir
	$conf_dir
	$conf_file
	%config
);

$< == 0 or die "This script requires root privileges.\n";

use Tie::File;
use Sort::Versions;
use Digest::MD5;
use File::Copy;
use File::Path qw(make_path remove_tree);
use File::Temp qw(tempdir tempfile);
use File::Find;
use File::Basename;
use Fcntl qw(F_SETFD F_GETFD);

our $tempdir = tempdir(CLEANUP => 1);

# define this to facilitate unit testing - should only ever be modified from
# t/test.t
our $pkg_db = '/var/log/packages';

# subroutine for throwing internal script errors
sub script_error(;$) {
	exists $_[0] ? die "A fatal script error has occurred:\n$_[0]\nExiting.\n"
				 : die "A fatal script error has occurred. Exiting.\n";
}

# sub for opening files, second arg is like '<','>', etc
sub open_fh {
	exists $_[1] or script_error 'open_fh requires two arguments';
	unless ($_[1] eq '>') {
		-f $_[0] or script_error "open_fh, $_[0] is not a file";
	}
	my ($file, $op) = @_;
	open my $fh, $op, $file or die "Unable to open $file.\n";
	return $fh;
}

sub open_read($) {
	return open_fh(shift, '<');
}

# global config variables
our $conf_dir = '/etc/sbotools';
our $conf_file = "$conf_dir/sbotools.conf";
our %config = (
	NOCLEAN => 'FALSE',
	DISTCLEAN => 'FALSE',
	JOBS => 'FALSE',
	PKG_DIR => 'FALSE',
	SBO_HOME => 'FALSE',
);

# subroutine to suck in config in order to facilitate unit testing
sub read_config() {
	my %conf_values;
	if (-f $conf_file) {
		my $fh = open_read $conf_file;
		my $text = do {local $/; <$fh>};
		%conf_values = $text =~ /^(\w+)=(.*)$/mg;
		close $fh;
	}
	for my $key (keys %config) {
		$config{$key} = $conf_values{$key} if exists $conf_values{$key};
	}
	$config{JOBS} = 'FALSE' unless $config{JOBS} =~ /^\d+$/;
	$config{SBO_HOME} = '/usr/sbo' if $config{SBO_HOME} eq 'FALSE';
}

read_config;

# some stuff we'll need later - define first two as our for unit testing
our $distfiles = "$config{SBO_HOME}/distfiles";
our $slackbuilds_txt = "$config{SBO_HOME}/SLACKBUILDS.TXT";
my $name_regex = '\ASLACKBUILD\s+NAME:\s+';

sub show_version() {
	say "sbotools version $VERSION";
	say 'licensed under the WTFPL';
	say '<http://sam.zoy.org/wtfpl/COPYING>';
}

# %supported maps what's in /etc/slackware-version to what's at SBo
# which is now not needed since this version drops support < 14.0
# but it's already future-proofed, so leave it.
sub get_slack_version() {
	my %supported = ('14.0' => '14.0');
	my $fh = open_read '/etc/slackware-version';
	chomp(my $line = <$fh>);
	close $fh;
	my $version = ($line =~ /\s+(\d+[^\s]+)$/)[0];
	die "Unsupported Slackware version: $version\n"
		unless $version ~~ %supported;
	return $supported{$version};
}

# does the SLACKBUILDS.TXT file exist in the sbo tree?
sub chk_slackbuilds_txt() {
	return -f $slackbuilds_txt ? 1 : undef;
}

# check for the validity of new $config{SBO_HOME}
sub check_home() {
	my $sbo_home = $config{SBO_HOME};
	if (-d $sbo_home) {
		opendir(my $home_handle, $sbo_home);
		FIRST: while (readdir $home_handle) {
			next FIRST if /^\.[\.]{0,1}$/;
			die "$sbo_home exists and is not empty. Exiting.\n";
		}
	} else {
		make_path($sbo_home) or die "Unable to create $sbo_home.\n";
	}
	return 1;
}

# rsync the sbo tree from slackbuilds.org to $config{SBO_HOME}
sub rsync_sbo_tree() {
	my $slk_version = get_slack_version;
	my @arg = ('rsync', '-a', '--exclude=*.tar.gz', '--exclude=*.tar.gz.asc');
	push @arg, '--delete', "rsync://slackbuilds.org/slackbuilds/$slk_version/*";
	my $out = system @arg, $config{SBO_HOME};
	my $wanted = sub {
		$File::Find::name ? chown 0, 0, $File::Find::name
						  : chown 0, 0, $File::Find::dir;
	};
	find($wanted, $config{SBO_HOME});
	say 'Finished.' and return $out;
}

# wrappers for differing checks and output
sub fetch_tree() {
	check_home;
	say 'Pulling SlackBuilds tree...';
	rsync_sbo_tree, return 1;
}

sub update_tree() {
	fetch_tree, return unless chk_slackbuilds_txt;
	say 'Updating SlackBuilds tree...';
	rsync_sbo_tree, return 1;
}

# if the SLACKBUILDS.TXT is not in $config{SBO_HOME}, we assume the tree has
# not been populated there; prompt the user to automagickally pull the tree.
sub slackbuilds_or_fetch() {
	unless (chk_slackbuilds_txt) {
		say 'It looks like you haven\'t run "sbosnap fetch" yet.';
		print 'Would you like me to do this now? [y] ';
		<STDIN> =~ /^[Yy\n]/ ? fetch_tree :
			die "Please run \"sbosnap fetch\"\n";
	}
	return 1;
}

# pull an array of hashes, each hash containing the name and version of an sbo
# currently installed.
sub get_installed_sbos() {
	my @installed;
	# $1 == name, $2 == version
	my $regex = qr#/([^/]+)-([^-]+)-[^-]+-[^-]+$#;
	for my $path (<$pkg_db/*_SBo>) {
		my ($name, $version) = ($path =~ $regex)[0,1];
		push @installed, {name => $name, version => $version};
	}
	return \@installed;
}

# for a ref to an array of hashes of installed packages, return an array ref
# consisting of just their names
sub get_inst_names($) {
	exists $_[0] or script_error 'get_inst_names requires an argument.';
	my $inst = shift;
	my @installed;
	push @installed, $$_{name} for @$inst;
	return \@installed;
}

# search the SLACKBUILDS.TXT for a given sbo's directory
sub get_sbo_location {
	exists $_[0] or script_error 'get_sbo_location requires an argument.';
	my @sbos = @_;
	if (ref $sbos[0] eq 'ARRAY') {
		my $tmp = $sbos[0];
		@sbos = @$tmp;
	}
	state $store = {};
	# if scalar context and we already have the location, return it now.
	unless (wantarray) {
		return $$store{$sbos[0]} if exists $$store{$sbos[0]};
	}
	my %locations;
	my $fh = open_read $slackbuilds_txt;
	FIRST: for my $sbo (@sbos) {
		$locations{$sbo} = $$store{$sbo}, next FIRST if exists $$store{$sbo};
		my $regex = qr#LOCATION:\s+\.(/[^/]+/\Q$sbo\E)$#;
		while (my $line = <$fh>) {
			if (my $loc = ($line =~ $regex)[0]) {
				# save what we found for later requests
				$$store{$sbo} = "$config{SBO_HOME}$loc";
				return $$store{$sbo} unless wantarray;
				$locations{$sbo} = $$store{$sbo};
			}
		}
		seek $fh, 0, 0;
	}
	close $fh;
	return keys %locations > 0 ? %locations : undef;
}

# pull the sbo name from a $location: $config{SBO_HOME}/system/wine, etc.
sub get_sbo_from_loc($) {
	exists $_[0] or script_error 'get_sbo_from_loc requires an argument.';
	return (shift =~ qr#/([^/]+)$#)[0];
}

# pull piece(s) of data, GET, from the $sbo.info file under LOCATION.
sub get_from_info {
	my %args = (
		LOCATION	=> '',
		GET			=> '',
		@_
	);
	unless ($args{LOCATION} && $args{GET}) {
		script_error 'get_from_info requires LOCATION and GET.';
	}
	state $store = {PRGNAM => ['']};
	my $sbo = get_sbo_from_loc $args{LOCATION};
	return $$store{$args{GET}} if $$store{PRGNAM}[0] eq $sbo;
	# if we're here, we haven't read in the .info file yet.
	my $fh = open_read "$args{LOCATION}/$sbo.info";
	# suck it all in, clean it all up, stuff it all in $store.
	my $contents = do {local $/; <$fh>};
	$contents =~ s/("|\\\n)//g;
	$store = {$contents =~ /^(\w+)=(.*)$/mg};
	# fill the hash with array refs - even for single values,
	# since consistency here is a lot easier than sorting it out later
	for my $key (keys %$store) {
		if ($$store{$key} =~ /\s/) {
			my @array = split ' ', $$store{$key};
			$$store{$key} = \@array;
		} else {
			$$store{$key} = [$$store{$key}];
		}
	}
	return exists $$store{$args{GET}} ? $$store{$args{GET}} : undef;
}

# find the version in the tree for a given sbo (provided a location)
sub get_sbo_version($) {
	exists $_[0] or script_error 'get_sbo_version requires an argument.';
	my $version = get_from_info(LOCATION => shift, GET => 'VERSION');
	return $$version[0] ? $$version[0] : undef;
}

# for each installed sbo, find out whether or not the version in the tree is
# newer, and compile an array of hashes containing those which are
sub get_available_updates() {
	my @updates;
	my $pkg_list = get_installed_sbos; 
	FIRST: for my $key (keys @$pkg_list) {
		my $location = get_sbo_location($$pkg_list[$key]{name});
		# if we can't find a location, assume invalid and skip
		next FIRST unless defined $location;
		my $version = get_sbo_version $location;
		if (versioncmp($version, $$pkg_list[$key]{version}) == 1) {
			push @updates, {
				name		=> $$pkg_list[$key]{name},
				installed	=> $$pkg_list[$key]{version},
				update		=> $version
			};
		}
	}
	return \@updates;
}

# get downloads and md5sums from an sbo's .info file, first 
# checking for x86_64-specific info if we are told to
sub get_download_info {
	my %args = (
		LOCATION 	=> 0,
		X64 		=> 1,
		@_
	);
	$args{LOCATION} or script_error 'get_download_info requires LOCATION.';
	my ($get, $downs, $md5s, %return);
	$get = ($args{X64} ? 'DOWNLOAD_x86_64' : 'DOWNLOAD');
	$downs = get_from_info(LOCATION => $args{LOCATION}, GET => $get);
	# did we get nothing back, or UNSUPPORTED/UNTESTED?
	if ($args{X64}) {
		if (! $$downs[0] || $$downs[0] =~ qr/^UN(SUPPOR|TES)TED$/) {
			$args{X64} = 0;
			$downs = get_from_info(LOCATION => $args{LOCATION},
				GET => 'DOWNLOAD');
		}
	}
	# if we still don't have any links, something is really wrong.
	return unless $$downs[0];
	# grab the md5s and build a hash
	$get = $args{X64} ? 'MD5SUM_x86_64' : 'MD5SUM';
	$md5s = get_from_info(LOCATION => $args{LOCATION}, GET => $get);
	return unless $$md5s[0];
	$return{$$downs[$_]} = $$md5s[$_] for (keys @$downs);
	return %return;
}

sub get_arch() {
	chomp(my $arch = `uname -m`);
	return $arch;
}

# TODO: should probably combine this with get_download_info
sub get_sbo_downloads {
	my %args = (
		LOCATION	=> '',
		32			=> 0,
		@_
	);
	$args{LOCATION} or script_error 'get_sbo_downloads requires LOCATION.';
	my $location = $args{LOCATION};
	-d $location or script_error 'get_sbo_downloads given a non-directory.';
	my $arch = get_arch; 
	my %dl_info;
	if ($arch eq 'x86_64') {
		%dl_info = get_download_info(LOCATION => $location) unless $args{32};
	} 
	unless (keys %dl_info > 0) {
		%dl_info = get_download_info(LOCATION => $location, X64 => 0);
	}
	return %dl_info;
}

# given a link, grab the filename from it and prepend $distfiles
sub get_filename_from_link($) {
	exists $_[0] or script_error 'get_filename_from_link requires an argument';
	my $fn = shift;
	my $regex = qr#/([^/]+)$#;
	my $filename = $fn =~ $regex ? $distfiles .'/'. ($fn =~ $regex)[0] : undef;
	$filename =~ s/%2B/+/g if $filename;
	return $filename;
}

# for a given file, compute its md5sum
sub compute_md5sum($) {
	-f $_[0] or script_error 'compute_md5sum requires a file argument.';
	my $fh = open_read shift;
	my $md5 = Digest::MD5->new;
	$md5->addfile($fh);
	my $md5sum = $md5->hexdigest;
	close $fh;
	return $md5sum;
}

# for a given distfile, see whether or not it exists, and if so, if its md5sum
# matches the sbo's .info file
sub verify_distfile {
	exists $_[1] or script_error 'verify_distfile requires two arguments.';
	my ($link, $info_md5) = @_;
	my $filename = get_filename_from_link $link;
	return unless -f $filename;
	my $md5sum = compute_md5sum $filename;
	return $info_md5 eq $md5sum ? 1 : 0;
}

# for a given distfile, attempt to retrieve it and, if successful, check its
# md5sum against that in the sbo's .info file
sub get_distfile {
	exists $_[1] or script_error 'get_distfile requires an argument';
	my ($link, $info_md5) = @_;
	my $filename = get_filename_from_link $link;
	mkdir $distfiles unless -d $distfiles;
	chdir $distfiles;
	system("wget --no-check-certificate $link") == 0 or
		die "Unable to wget $link\n";
	# can't do anything if the link in the .info doesn't lead to a good d/l
	verify_distfile(@_) ? return 1 : die "md5sum failure for $filename.\n";
	return 1;
}

# for a given distfile, figure out what the full path to its symlink will be
sub get_symlink_from_filename {
	exists $_[1] or script_error
		'get_symlink_from_filename requires two arguments';
	-f $_[0] or script_error
		'get_symlink_from_filename first argument is not a file';
	my ($filename, $location) = @_;
	return "$location/". ($filename =~ qr#/([^/]+)$#)[0];
}

# determine whether or not a given sbo is 32-bit only
sub check_x32($) {
	exists $_[0] or script_error 'check_x32 requires an argument.';
	my $dl = get_from_info(LOCATION => shift, GET => 'DOWNLOAD_x86_64');
	return $$dl[0] =~ /UN(SUPPOR|TES)TED/ ? 1 : undef;
}

# can't do 32-bit on x86_64 without this file, so we'll use it as the test to
# to determine whether or not an x86_64 system is setup for multilib
sub check_multilib() {
	return 1 if -f '/etc/profile.d/32dev.sh';
	return;
}

# given a list of downloads, return just the filenames
sub get_dl_fns($) {
	my $fns = shift;
	my $return;
	push @$return, ($_ =~ qr|/([^/]+)$|)[0] for @$fns;
	return $return;
}

# given a line that looks like it's decompressing something, try to return a
# valid filename regex
sub get_dc_regex {
	my $line = shift;
	# get rid of initial 'tar x'whatever stuff
	$line =~ s/^.*(?<![a-z])(tar|p7zip|unzip|ar|rpm2cpio|sh)\s+[^\s]+\s+//;
	# need to know preceeding character - should be safe to assume it's either
	# a slash or a space
	my $initial = $line =~ qr|/| ? '/' : ' ';
	# get rid of initial path info
	$line =~ s|^\$[^/]+/||;
	# convert any instances of command substitution to [^-]+
	$line =~ s/\$\([^)]+\)/[^-]+/g;
	# convert any bash variables to [^-]+
	$line =~ s/\$({|)[A-Za-z0-9_]+(}|)/[^-]+/g;
	# get rid of anything excess at the end
	$line =~ s/\s+.*$//;
	# fix .?z* at the end
	$line =~ s/\.\?z\*/\.[a-z]z.*/;
	# return what's left as a regex
	my $regex = qr/$initial$line/;
	return $regex, $initial;
}

# make a backup of the existent SlackBuild, and rewrite the original as needed
sub rewrite_slackbuild {
	my %args = (
		SBO			=> '',
		SLACKBUILD	=> '',
		CHANGES		=> {}, 
		C32			=> 0,
		@_
	);
	$args{SLACKBUILD} or script_error 'rewrite_slackbuild requires SLACKBUILD.';
	my $slackbuild = $args{SLACKBUILD};
	my $changes = $args{CHANGES};
	copy($slackbuild, "$slackbuild.orig") or
		die "Unable to backup $slackbuild to $slackbuild.orig\n";
	my $libdir_regex = qr/^\s*LIBDIRSUFFIX="64"\s*$/;
	my $arch_regex = qr/\$VERSION-\$ARCH-\$BUILD/;
	my $dc_regex = qr/(?<![a-z])(tar|p7zip|unzip|ar|rpm2cpio|sh)\s+/;
	# tie the slackbuild, because this is the easiest way to handle this.
	tie my @sb_file, 'Tie::File', $slackbuild;
	# if we're dealing with a compat32, we need to change the tar line(s) so
	# that the 32-bit source is untarred
	if ($args{C32}) {
		my $location = get_sbo_location($args{SBO});
		my %downloads = get_sbo_downloads(
			LOCATION => $location,
			32 => 1,
		);
		my $fns = get_dl_fns [keys %downloads];
		for my $line (@sb_file) {
			if ($line =~ $dc_regex) {
				my ($regex, $initial) = get_dc_regex $line;
				for my $fn (@$fns) {
					$fn = "$initial$fn";
					$line =~ s/$regex/$fn/ if $fn =~ $regex;
				}
			}
		}
	}
	for my $line (@sb_file) {
		# then check for and apply any other %$changes
		if (exists $$changes{libdirsuffix}) {
			$line =~ s/64/$$changes{libdirsuffix}/ if $line =~ $libdir_regex;
		}
		if (exists $$changes{arch_out}) {
			$line =~ s/\$ARCH/$$changes{arch_out}/ if $line =~ $arch_regex;
		}
	}
	untie @sb_file;
	return 1;
}

# move a backed-up .SlackBuild file back into place
sub revert_slackbuild($) {
	exists $_[0] or script_error 'revert_slackbuild requires an argument';
	my $slackbuild = shift;
	if (-f "$slackbuild.orig") {
		unlink $slackbuild if -f $slackbuild;
		rename "$slackbuild.orig", $slackbuild;
	}
	return 1;
}

# for each $download, see if we have it, and if the copy we have is good,
# otherwise download a new copy
sub check_distfiles {
	exists $_[0] or script_error 'check_distfiles requires an argument.';
	my %dists = @_;
	while (my ($link, $md5) = each %dists) {
		get_distfile($link, $md5) unless verify_distfile($link, $md5);
	}
	return 1;
}

# given a location and a list of download links, assemble a list of symlinks,
# and create them.
sub create_symlinks {
	exists $_[1] or script_error 'create_symlinks requires two arguments.';
	my ($location, %downloads) = @_;
	my @symlinks;
	for my $link (keys %downloads) {
		my $filename = get_filename_from_link $link;
		my $symlink = get_symlink_from_filename($filename, $location);
		push @symlinks, $symlink;
		symlink $filename, $symlink;
	}
	return @symlinks;
}

# pull the untarred source directory or created package name from the temp
# file (the one we tee'd to)
sub grok_temp_file {
	my %args = (
		FH		=> '',
		REGEX	=> '',
		CAPTURE	=> 0,
		@_
	);
	unless ($args{FH} && $args{REGEX}) {
		script_error 'grok_temp_file requires two arguments';
	}
	my $fh = $args{FH};
	seek $fh, 0, 0;
	my $out;
	FIRST: while (my $line = <$fh>) {
		if ($line =~ $args{REGEX}) {
			$out = ($line =~ $args{REGEX})[$args{CAPTURE}];
			last FIRST;
		}
	}
	return $out;
}

# wrappers around grok_temp_file
sub get_src_dir($) {
	exists $_[0] or script_error 'get_src_dir requires an argument';
	return grok_temp_file(FH => shift, REGEX => qr#^([^/]+)/#);
}

sub get_pkg_name($) {
	exists $_[0] or script_error 'get_pkg_name requires an argument';
	return grok_temp_file(FH => shift, 
		REGEX => qr/^Slackware\s+package\s+([^\s]+)\s+created\.$/);
}

# return a filename from a temp fh for use externally
sub get_tmp_extfn($) {
	exists $_[0] or script_error 'get_tmp_extfn requires an argument.';
	my $fh = shift;
	fcntl($fh, F_SETFD, 0) or die "Can't unset exec-on-close bit\n";
	return '/dev/fd/'. fileno $fh;
}

# prep and run .SlackBuild
sub perform_sbo {
	my %args = (
		OPTS		=> 0, 
		JOBS		=> 0,
		LOCATION	=> '',
		ARCH		=> '',
		C32			=> 0,
		X32			=> 0,
		@_
	);
	unless ($args{LOCATION} && $args{ARCH}) {
		script_error 'perform_sbo requires LOCATION and ARCH.';
	}

	my $location = $args{LOCATION};
	my $sbo = get_sbo_from_loc $location;
	my ($cmd, %changes);
	# set any changes we need to make to the .SlackBuild, setup the command
	
	$cmd = '( ';
	$args{JOBS} = 0 if $args{JOBS} eq 'FALSE';

	if ($args{ARCH} eq 'x86_64' and ($args{C32} || $args{X32})) {
		if ($args{C32}) {
			$changes{libdirsuffix} = '';
		} elsif ($args{X32}) {
			$changes{arch_out} = 'i486';
		}
		$cmd .= '. /etc/profile.d/32dev.sh &&';
	}
	$cmd .= " $args{OPTS}" if $args{OPTS};
	$cmd .= " MAKEOPTS=\"-j$args{JOBS}\"" if $args{JOBS};
	# get a tempfile to store the exit status of the slackbuild
	my $exit_temp = tempfile(DIR => $tempdir);
	my $exit_fn = get_tmp_extfn $exit_temp;
	$cmd .= " /bin/sh $location/$sbo.SlackBuild; echo \$? > $exit_fn )";
	my $tempfh = tempfile(DIR => $tempdir);
	my $fn = get_tmp_extfn $tempfh;
	$cmd .= " | tee -a $fn";
	rewrite_slackbuild(
		SBO => $sbo,
		SLACKBUILD => "$location/$sbo.SlackBuild",
		CHANGES => \%changes,
		C32 => $args{C32},
	);
	chdir $location, system $cmd;
	seek $exit_temp, 0, 0;
	my $out = do {local $/; <$exit_temp>};
	revert_slackbuild "$location/$sbo.SlackBuild";
	die "$sbo.SlackBuild returned non-zero exit status\n" unless $out == 0;
	my $pkg = get_pkg_name $tempfh;
	my $src = get_src_dir $tempfh;
	return $pkg, $src;
}

# run convertpkg on a package to turn it into a -compat32 thing
sub do_convertpkg($) {
	exists $_[0] or script_error 'do_convertpkg requires an argument.';
	my $pkg = shift;
	my $tempfh = tempfile(DIR => $tempdir);
	my $fn = get_tmp_extfn $tempfh;
	my $cmd = "/usr/sbin/convertpkg-compat32 -i $pkg -d /tmp | tee $fn";
	system($cmd) == 0 or
		die "convertpkg-compt32 returned non-zero exit status\n";
	unlink $pkg;
	return get_pkg_name $tempfh;
}

# "public interface", sort of thing.
sub do_slackbuild {
	my %args = (
		OPTS		=> 0, 
		JOBS		=> 0,
		LOCATION	=> '',
		COMPAT32	=> 0,
		@_
	);
	$args{LOCATION} or script_error 'do_slackbuild requires LOCATION.';
	my $location = $args{LOCATION};
	my $sbo = get_sbo_from_loc $location;
	my $arch = get_arch; 
	my $multilib = check_multilib;
	my $version = get_sbo_version $location;
	my $x32;
	# ensure x32 stuff is set correctly, or that we're setup for it
	if ($args{COMPAT32}) {
		die "compat32 requires multilib.\n" unless $multilib;
		die "compat32 requires /usr/sbin/convertpkg-compat32.\n"
				unless -f '/usr/sbin/convertpkg-compat32';
	} else {
		if ($arch eq 'x86_64') {
			$x32 = check_x32 $args{LOCATION};
			if ($x32 && ! $multilib) {
				die "$sbo is 32-bit which requires multilib on x86_64.\n";
			}
		}
	}
	# get a hash of downloads and md5sums, ensure we have 'em, symlink 'em
	my %downloads = get_sbo_downloads(
		LOCATION => $location,
		32 => $args{COMPAT32}
	);
	check_distfiles %downloads;
	my @symlinks = create_symlinks($args{LOCATION}, %downloads);
	# setup and run the .SlackBuild itself
	my ($pkg, $src) = perform_sbo(
		OPTS => $args{OPTS},
		JOBS => $args{JOBS},
		LOCATION => $location,
		ARCH => $arch,
		C32 => $args{COMPAT32},
		X32 => $x32,
	);
	$pkg = do_convertpkg $pkg if $args{COMPAT32};
	unlink $_ for @symlinks;
	return $version, $pkg, $src;
}

# remove work directories (source and packaging dirs under /tmp/SBo)
sub make_clean {
	my %args = (
		SBO		=> '',
		SRC		=> '',
		VERSION	=> '',
		@_
	);
	unless ($args{SBO} && $args{SRC} && $args{VERSION}) {
		script_error 'make_clean requires three arguments.';
	}
	say "Cleaning for $args{SBO}-$args{VERSION}...";
	my $tmpsbo = '/tmp/SBo';
	remove_tree("$tmpsbo/$args{SRC}") if -d "$tmpsbo/$args{SRC}";
	remove_tree("$tmpsbo/package-$args{SBO}") if
		-d "$tmpsbo/package-$args{SBO}";
	return 1;
}

# remove distfiles
sub make_distclean {
	my %args = (
		SRC			=> '',
		VERSION		=> '',
		LOCATION	=> '',
		@_
	);
	unless ($args{SRC} && $args{VERSION} && $args{LOCATION}) {
		script_error 'make_distclean requires four arguments.';
	}
	my $sbo = get_sbo_from_loc $args{LOCATION};
	make_clean(SBO => $sbo, SRC => $args{SRC}, VERSION => $args{VERSION});
	say "Distcleaning for $sbo-$args{VERSION}...";
	# remove any distfiles for this particular SBo.
	my %downloads = get_sbo_downloads(LOCATION => $args{LOCATION});
	for my $key (keys %downloads) {
		my $filename = get_filename_from_link $key;
		unlink $filename if -f $filename;
	}
	return 1;
}

# run upgradepkg for a created package
sub do_upgradepkg($) {
	exists $_[0] or script_error 'do_upgradepkg requires an argument.';
	system('/sbin/upgradepkg', '--reinstall', '--install-new', shift);
	return 1;
}

# wrapper to pull the list of requirements for a given sbo
sub get_requires($) {
	my $location = get_sbo_location(shift);
	return unless $location;
	my $info = get_from_info(LOCATION => $location, GET => 'REQUIRES');
	return $$info[0] ne '' ? $info : undef;
}

# avoid being called to early to check prototype when add_to_queue calls itself
sub add_to_queue($);
# used by get_build_queue. 
sub add_to_queue($) {
	my $args = shift;
	my $sbo = \${$args}{NAME};
	return unless $$sbo;
	push @$args{QUEUE}, $$sbo;
	my $requires = get_requires $$sbo;
	FIRST: for my $req (@$requires) {
		next FIRST if $req eq $$sbo;
		if ($req eq "%README%") {
			${$args}{WARNINGS}{$$sbo}="%README%";
		} else {
			$$sbo = $req;
			add_to_queue($args);
		}
	}	
}

# recursively add a sbo's requirements to the build queue.
sub get_build_queue {
	exists $_[1] or script_error 'get_build_queue requires two arguments.';
	my ($sbos, $warnings) = @_;
	my $temp_queue = [];
	for my $sbo (@$sbos) {
		my %args = (
			QUEUE 	  => $temp_queue,
			NAME 	  => $sbo,
			WARNINGS  => $warnings
		);
		add_to_queue(\%args);
	}
	# Remove duplicate entries (leaving first occurrence)
	my (%seen, @build_queue);
	FIRST: for my $sb (@$temp_queue) {
		 next FIRST if $seen{$sb}++;
		 push @build_queue, $sb;
	}
	return \@build_queue;
}

sub merge_queues {
	# Usage: merge_queues(\@queue_a, \@queue_b);
	# Results in queue_b being merged into queue_a (without duplicates)
	exists $_[1] or script_error 'merge_queues requires two arguments.';
    my $queue_a = $_[0];
    my $queue_b = $_[1];

    for my $item (reverse @$queue_b) {
        push @$queue_a, $item unless $item ~~ @$queue_a;
    }
    return $queue_a;
}

sub get_readme_contents($) {
	exists $_[0] or script_error 'get_readme_contents requires an argument.';
	my $fh = open_read(shift .'/README');
	my $readme = do {local $/; <$fh>};
	close $fh;
	return $readme;
}
