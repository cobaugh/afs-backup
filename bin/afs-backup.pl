#!/usr/bin/perl 

# $Id$

use strict;
use File::Find;
use Cwd;
#use String::ShellQuote;
use Getopt::Long;
use Sys::Hostname;


my ($tmp, @tmp_array, $file, %config, $i, $k, $v, $path);
my ($mntpt, $type, $volume, $cell, %mounts_by_path, %mounts_by_volume);

my $hostname = hostname();

Getopt::Long::Configure('bundling');
GetOptions(
	'h|help' => \(my $opt_help = 0),
	'v|verbose' => \(my $opt_verbose = 0),
	'q|quiet' => \(my $opt_quiet = 0),
	'p|pretend' => \(my $opt_pretend = 0),
	'm|mode=s' => \(my $mode = 'none'),
	'tsm-node-name=s' => \(my $tsmnode = $hostname),
	'force-hostname=s' => \($hostname = $hostname)
);

my $shorthostname = $hostname;
$shorthostname =~ s/\..*//;

my $afsbackup = $ENV{'AFSBACKUP'};
if ($afsbackup !~ m/^\//) {
	print "AFSBACKUP should really be absolute\n\n";
	exit 1;
}

print "\$afsbackup = $afsbackup\n";
print "\$hostname = $hostname\n";
print "\$shorthostname = $shorthostname\n";

if ($opt_help) {
	exec('perldoc', '-t', $0) or die "Cannot feed myself to perldoc\n";
	exit 0;
} elsif ($mode eq "none" or $afsbackup eq "") {
	print "Usage: $0 [-h|--help] [-p|pretend] [-v|--verbose] [-q|--quiet] [--tsm-node-name NODENAME] [--force-hostname HOSTNAME]\n
	-m|--mode [tsm|shadow|find-mounts|vosbackup|vosrelease|vosdump]\n\n";
	print "AFSBACKUP must also be defined\n\n";
	exit 0;
}

# read in configuration common to all modes
my @configfiles_single_common = (
	'basepath',
	'thiscell'
);

foreach $file (@configfiles_single_common) {
	foreach ('common', "hosts/$shorthostname") {
		$tmp = read_file_single("$afsbackup/etc/$_/$file");
		if ($tmp ne 0 and $tmp ne "") {
			print "$file = $tmp\n";
			$config{$file} = $tmp;
		}
	}
}

if ($opt_verbose) {
	print "\n=== Common Configuration (\$config) ===\n";
	foreach (@configfiles_single_common) {
		printf "$_ = %s\n", $config{$_};
	}
}

# read in mounts-by-path and mounts-by-volume
if ($mode ne 'find-mounts') {
	# mounts-by-foo is created either weekly or nightly, probably weekly
	%mounts_by_path = read_mounts_by_path("$afsbackup/var/mounts/mounts-by-path");
	%mounts_by_volume = read_mounts_by_volume("$afsbackup/var/mounts/mounts-by-volume");

	if ($opt_verbose) {
		print "Mounts by path:\n";
		foreach (keys %mounts_by_path) {
			printf "\t$_ = %s\n", $mounts_by_path{$_}{'volume'};
		}

		print "Mounts by volume:\n";
		foreach $tmp (keys %mounts_by_volume) {
			printf "\t$tmp (%s) = \n", $mounts_by_volume{$tmp}{'cell'};
			foreach (keys %{$mounts_by_volume{$tmp}{'paths'}}) {
					printf "\t\t%s %s\n", $mounts_by_volume{$tmp}{'paths'}{$_}, $_;
			}
		}
	}
} else {
	print "Requested mode find-mounts\n";
	if (@ARGV ne 1 or $ARGV[0] !~ /^\//) {
		print "-m find-mounts takes one argument: absolute path to traverse\n\n";
		exit 1
	}
	mode_find_mounts($ARGV[0]);
	exit 0;
}

if ($mode eq 'tsm') {
	print "\nRequested mode TSM\n";
	mode_tsm();
	exit 0;
} else {
	print "\nInvalid mode: $mode\n\n";
	exit 1;
}

exit 0;

# TSM mode
sub mode_tsm {
	my (%policy, $exclude_from_backup, @backup, %backup_hash, %nobackup);

	if (!$opt_quiet) {
		print "TSM Node: $tsmnode\n";
	}
	# these are single-valued (single-line) config files
	my @configfiles_single = (
		'tsm-policy-default',
		'tsm-policy-order',
		'tsm-backup-tmp-mount-path'
	);

	##
	## read in $config 
	##
	# single-line single-value
	foreach $file (@configfiles_single) {
		foreach ('common', "hosts/$shorthostname") {
			$tmp = read_file_single("$afsbackup/etc/$_/$file");
			if ($tmp ne 0 and $tmp ne "") {
				$config{$file} = $tmp;
			}
		}
	}

	# policies (management classes)
	foreach $file ('tsm-policy-by-path', 'tsm-policy-by-volume') {
		$i = 0;
		foreach ('common', "hosts/$shorthostname") {
			@tmp_array = read_file_multi("$afsbackup/etc/$_/$file");
			if (@tmp_array) {
				foreach (@tmp_array) {
					# we get the lines back in order from top to bottom
					($k, $v) = split(/\s+/, $_);
					# we then put items onto the array keyed by $i in order they 
					# appear in the file, from top to bottom
					$config{$file}[$i] = { k => $k, v => $v };
					$i++;
				}
			}
		}
	}

	# what to backup into tsm
	foreach $file ('tsm-backup-by-path', 'tsm-backup-by-volume') {
		$i = 0;
		foreach ('common', "hosts/$shorthostname") {
			@tmp_array = read_file_multi("$afsbackup/etc/$_/$file");
			if (@tmp_array) {
				foreach (@tmp_array) {
					$config{$file}[$i] = $_;
					$i++;
				}
			}
		}
	}

	# spit out debugging info about configuration
	if ($opt_verbose) {
		print "\n=== TSM Configuration (\$config) ===\n";
		foreach (@configfiles_single) {
			printf "$_ = %s\n", $config{$_};
		}

		foreach ('tsm-backup-by-path', 'tsm-backup-by-volume') {
			print "\n$_ =\n";
			$i = 0;
			for ($i = 0; $i <= $#{$config{$_}}; $i++) {
				printf "\t$i = %s\n", $config{$_}[$i];
			}
		}

		foreach ('tsm-policy-by-path', 'tsm-policy-by-volume') {
			print "\n$_ =\n";
			$i = 0;
			for ($i = 0; $i <= $#{$config{$_}}; $i++) {
				printf "\t$i = %s : %s\n", $config{$_}[$i]{'k'}, $config{$_}[$i]{'v'};
			}
		}
	}

	# set up exclude.list
	my $inclexcl = "$afsbackup/var/tmp/exclude.$tsmnode";
	cmd("rm -f $inclexcl");
	cmd("cp $afsbackup/etc/common/exclude.list $inclexcl");
	cmd("cat $afsbackup/etc/hosts/$shorthostname/exclude.list >> $inclexcl");

	# start writing dsm.sys
	my $dsmsys = "$afsbackup/var/tmp/dsm.sys.$tsmnode";
	cmd("rm -f $dsmsys");
	cmd("cp $afsbackup/etc/common/dsm.sys.head $dsmsys");
	cmd("cat $afsbackup/etc/hosts/$shorthostname/dsm.sys.head >> $dsmsys");

	if ( -e "$dsmsys" ) {
		open (HANDLE, '>>', $dsmsys);
		print HANDLE "INCLEXCL $inclexcl\n";
		# virtualmounts based on all afs mount points
		printf HANDLE "VirtualMountPoint %s\n", $config{'basepath'};
		foreach (sort keys %mounts_by_path) {
			printf HANDLE "VirtualMountPoint %s\n", $_;
		}
	} else {
		print "Failed to create $dsmsys. This shouldn't happen.\n";
		exit 1;
	}

	# determine what to backup by path
	foreach $path (keys %mounts_by_path) {
		next if $mounts_by_path{$path}{'type'} ne '#';
		for ($i = 0; $i <= $#{$config{'tsm-backup-by-path'}}; $i++) {
			$tmp = $config{'tsm-backup-by-path'}[$i];
			$exclude_from_backup = 0;
			if ($tmp =~ m/^\!/) {
				$exclude_from_backup = 1;
				$tmp =~ s/^\!//;
			}
			if ($tmp !~ /^\//) {
				$tmp = $config{'basepath'} . '/' . $tmp;
			}
			$path =~ s/\/+/\//; # get rid of duplicate /'s
			$path =~ s/\/$//; # remove any trailing /'s
			$tmp =~ s/\/+/\//; # get rid of duplicate /'s
			$tmp =~ s/\/$//; # remove any trailing /'s
			if ($path =~ m/$tmp/) {
				if ($exclude_from_backup) {
					$nobackup{$path} = 1;
				} else {
					push @backup, $path;
					if (! $nobackup{$path} ) {
						#$nobackup{$path} = 0;
					}
				}
			}
		}
	}

	# determine what to backup by volume
	foreach $volume (keys %mounts_by_volume) {
		for ($i = 0; $i <= $#{$config{'tsm-backup-by-volume'}}; $i++) {
			$tmp = $config{'tsm-backup-by-volume'}[$i]; # looping this way ensures $tmp is a copy
			$exclude_from_backup = 0;
			if ($tmp =~ m/^\!/) {
				$exclude_from_backup = 1;
				$tmp =~ s/^\!//;
			}
			if ($volume =~ m/$tmp/) {
				# get the first 'normal' mount
				foreach (keys %{$mounts_by_volume{$volume}{'paths'}}) {
					if ($mounts_by_volume{$volume}{'paths'}{$_} eq '#') {
						if ($exclude_from_backup) {
							$nobackup{$_} = 1;
						} else {
							push @backup, $_;
							if (! $nobackup{$path} ) {
								#$nobackup{$_} = 0;
							}
						}
						last;
					}
				}
			}
		}
	}
	
	# this seems kinda more kludgy than usual. Removes duplicates
	# and skips those paths that we don't want to backup
	# %nobackup was an afterthought, should probably rethink
	for ($i = 0; $i <= $#backup; $i++) {
		if ($nobackup{$backup[$i]} ne 1) {
			$backup_hash{$backup[$i]} = 1;
		}
	}
	
	# sanity check tsm-policy-order
	if ($config{'tsm-policy-order'} !~ /(path\s+volume)|(volume\s+path)/) {
		print "Syntax error in tsm-policy-order. Expecting one of \"path volume\" or \"volume path\"\n";
		exit 1;
	} 
	# determine management class to use
	foreach $tmp (split(/\s+/, $config{'tsm-policy-order'})) {
		if ($tmp eq 'path') {
			foreach $path (keys %backup_hash) {
				# run through tsm-policy-by-path in reverse order
				for ($i = $#{$config{'tsm-policy-by-path'}}; $i >= 0; $i--) {
					if ($path =~ m/$config{'tsm-policy-by-path'}[$i]{'k'}/) {
						$policy{$path} = $config{'tsm-policy-by-path'}[$i]{'v'};
					} elsif (!$policy{$path}) {
						$policy{$path} = '';
					}

				}
			}
		}
		if ($tmp eq 'volume') {
			foreach $path (keys %backup_hash) {
				# run through tsm-policy-by-path in reverse order
				for ($i = $#{$config{'tsm-policy-by-volume'}}; $i >= 0; $i--) {
					if ($mounts_by_path{$path}{'volume'} =~ m/$config{'tsm-policy-by-volume'}[$i]{'k'}/) {
						$policy{$path} = $config{'tsm-policy-by-volume'}[$i]{'v'};
					} elsif (!$policy{$path}) {
						$policy{$path} = '';
					}

				}
			}
		}
	}

	if (!$opt_quiet) {
		print "\nPaths/mountpoints to backup:\n";
		print "PATH | VOLUME | MGMTCLASS\n";
		foreach (sort { length $a <=> length $b || $a cmp $b } keys %backup_hash) {
			printf "%s | %s | %s\n", $_, $mounts_by_path{$_}{'volume'}, $policy{$_};
		}
	}

	# default management class
	if ($config{'tsm-policy-default'} ne "") {
		printf HANDLE "\n* Default management class (policy-default)\ninclude * %s\n\n", $config{'tsm-policy-default'};
	}
	# per-path management class
	print HANDLE "\n* per-path management classes\n";
	foreach (sort { length $a <=> length $b || $a cmp $b } keys %backup_hash) {
		if ($policy{$_} ne '') {
			printf HANDLE "INCLUDE %s/* %s\n", $_, $policy{$_};
			printf HANDLE "INCLUDE %s/.../* %s\n", $_, $policy{$_};
		}
	}
	close (HANDLE); # close dsm.sys.$tsmnode

	# make sure a .backup volume exists for every volume
	# vos backup if not
	# then mount each volume
	if (!$opt_quiet) {
		print "Creating .backup volumes if needed, and mounting .backup volumes\n";
	}
	foreach $tmp (keys %backup_hash) {
		print "path: $tmp\n";
		if (! cmd("vos exam $mounts_by_path{$tmp}{'volume'}.backup >/dev/null 2>&1") ){
			if ($opt_verbose) {
				printf "No backup volume for %s\n", $mounts_by_path{$tmp}{'volume'};
				cmd("vos backup $mounts_by_path{$tmp}{'volume'}");
			}
		}
		cmd("fs rmm $config{'tsm-backup-tmp-mount-path'}/$mounts_by_path{$tmp}{'volume'}");
		cmd("fs mkm $config{'tsm-backup-tmp-mount-path'}/$mounts_by_path{$tmp}{'volume'} $mounts_by_path{$tmp}{'volume'}.backup");
	}

	# dump vldb
	print "Dumping VLDB metadata to $afsbackup/var/vldb/vldb.date\n";
	cmd("$afsbackup/bin/dumpvldb.sh $afsbackup/var/vldb/vldb.`date +%Y%m%d-%H%M%S`");

	# dump acls
	print "Dumping ACLs\n";
	foreach $tmp (keys %backup_hash) {
		printf "%s (%s)\n", $tmp, $mounts_by_path{$tmp}{'volume'};
		$volume = $mounts_by_path{$tmp}{'volume'};
		cmd("find $config{'tsm-backup-tmp-mount-path'}/$volume -type d -exec fs listacl {} \\; > $afsbackup/var/acl/$volume");
	}

	# run dsmc incremental
	print "Running dsmc incremental\n";
	cmd("mv $afsbackup/var/log/dsmc.log.$tsmnode $afsbackup/var/log/dsmc.log.$tsmnode.last ; 
		mv $afsbackup/var/log/dsmc.error.$tsmnode $afsbackup/var/log/dsmc.error.$tsmnode.last");

	foreach $tmp (keys %backup_hash) {
		printf "%s (%s)\n", $tmp, $mounts_by_path{$tmp}{'volume'};
		$volume = $mounts_by_path{$tmp}{'volume'};
		cmd("dsmc incremental $tmp -snapshotroot=$config{'tsm-backup-tmp-mount-path'}/$volume 
			>>$afsbackup/var/log/dsmc.log.$tsmnode 2>>$afsbackup/var/log/dsmc.error.$tsmnode");
	}

} # END mode_tsm()

# find-mounts mode
sub mode_find_mounts {
	($path) = @_;
	$path =~ s/\/$//; # get rid of trailing /
	my $filename = $path;
	$filename =~ s/^\///; # get rid of leading /
	$filename =~ s/\//-/g; # replace remaining /'s with -
	if (!$opt_quiet) {
		print "Going to get mounts for $path\n";
		print "Mounts will be put in $afsbackup/var/mounts/$filename-* and mounts-by-* will be updated\n";
	}
	cmd("rm -f $afsbackup/var/mounts/$filename*");
	cmd("afs-find-mounts.pl -lm $path $afsbackup/var/mounts/$filename");
	cmd("cat $afsbackup/var/mounts/*-by-mount > $afsbackup/var/mounts/mounts-by-path 2>/dev/null");
	cmd("cat $afsbackup/var/mounts/*-by-volume > $afsbackup/var/mounts/mounts-by-volume 2>/dev/null");

}

#
# miscellaneous functions
#

sub cmd {
	my @command = @_;
	my (@output, $status);

	if ($opt_pretend) {
		printf "[cmd] %s\n", @command;
		return 1;
	}
	$| = 1;
	my $pid = open (OUT, '-|');
	if (!defined $pid)
	{
		die "unable to fork: $!";
	} elsif ($pid eq 0) {
		open (STDERR, '>&STDOUT') or die "cannot dup stdout: $!";
		exec @command or die "cannot exec $command[0]: $!";
	} else {
		while (<OUT>)
		{
			if ($opt_verbose eq 1) {
				print "$_";
			}
			push (@output, $_);
		}
		#waitpid ($pid, 0);
		$status = $?;
		close OUT;
	}
	return ($status == 0);
}

sub read_file_single {
	my ($file) = @_;
	if ($opt_verbose) {
		print "reading in $file\n";
	}
	if ( -e "$file" ) {
		open (HANDLE, '<', $file) or print "cannot open file $file: $!\n";
		local $_;
		while (<HANDLE>) {
			next if /^\s*\#/; # skip comments
			next if /^\s*$/; # skip blank lines
			s/\n//;
			return $_;
		}
	} else {
		return 0;
	}
}

sub read_file_multi {
	my ($file) = @_;
	my @return = ();
	if ($opt_verbose) {
		print "reading in $file\n";
	}
	if ( -e "$file" ) {
		open (HANDLE, '<', $file) or print "cannot open file $file: $!\n";
		local $_;
		while (<HANDLE>) {
			next if /^\s*\#/; # skip comments
			next if /^\s*$/; # skip blank lines
			s/\n//;
			push @return, $_; 
		}
	}
	return @return;
}

sub read_mounts_by_volume {
	my ($file) = @_;
	my %return;
	my @paths = ();
	my ($vol, $cell, $path, $type);
	if ( -e "$file" ) {
		open (HANDLE, '<', $file) or print "cannot open file $file: $!\n";
		local $_;
		while (<HANDLE>) {
			# this shouldn't happen, but skip path lines
			next if /^\s*\#/;
			next if /^\s*\%/;
			# get the volume|cell line
			s/\n//;
			($vol, $cell) = split(/\|/, $_);
			@paths = (); # clear the paths
			while (<HANDLE>) {
				last if /^\s*$/; # blank lines mark end of this volume block
				# get the paths
				s/\n//;
				s/^\s*//;
				push @paths, $_;
			}
			$return{$vol}{'cell'} = $cell;
			foreach (@paths) {
				($type, $path) = split(/\s+/, $_);
				$return{$vol}{'paths'}{$path} = $type;
			}
		}
	}
	return %return;
}

sub read_mounts_by_path {
	my ($file) = @_;
	my %return;
	my @tmp_array;
	if ( -e "$file" ) {
		open (HANDLE, '<', $file) or print "cannot open file $file: $!\n";
		while (<HANDLE>) {
			next if /^\s*$/; # skip blank lines
			s/\n//;
			push @tmp_array, [ split(/\|/, $_) ];
		}
	}
	for $i (0 .. $#tmp_array) {
		($mntpt, $type, $volume, $cell) = @{$tmp_array[$i]};
		$return{$mntpt} = { 
			type => $type,
			volume => $volume,
			cell => $cell
		};
	}
	return %return;
}
		

__END__

=head1 NAME

afs-backup.pl - Performs various backup-type operations for AFS

=head1 SYNOPSIS

 afs-backup.pl OPTIONS

=head1 OPTIONS

=over 8

=item B<-h>, B<help>

Print this documentation

=item B<-v>, B<--verbose>

Say what we're doing at each step of the process

=item B<-q>, B<--quiet>

Only print the mounts by mount or by volume with no processing information. NOT mutually exclusive with --verbose

=item B<-l>, B<--by-volume>

Print mount points by volume name

=item B<-m>, B<--by-mount>

Print mount points by mount point path

=item B<PATH>

Path to dive into. This can either be relative or absolute. 

=cut