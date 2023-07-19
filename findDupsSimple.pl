#!/bin/perl -w
use strict;

# Get the list first:
# find /mnt/d/sortedByYear/ -type 'f' -ls> allFiles1.txt ; find /mnt/d/tmpMove/ -type 'f' -ls >> allFiles1.txt ; cat allFiles1.txt |cut -c55- |sort -n > myFiles.txt; perl findDupsSimple.pl > runThisBash.sh
# This will produce output that can be run through bash (runThisBash.sh)
open F, "myFiles.txt";

my $prev = "";
my $prevFile = "";
my $prevSize = '';
while (<F>) {
	chomp;
	$_ =~ s/^\s+//;
	my $count = ($_ =~ m/^(\d+)\s(.+?)(\/.+$)/i);
	my $total = $#+;
	if ($total != 3) {
		print "##### Dif count: $total -- $_\n";
	}
	my $size = $1;
	my $date = $2;
	my $file = $3;

	
	if ("$size $date" eq $prev) {
		if ($size > 20000) {
			print "#- $size $date $file\n#+ $prev $prevFile\n";
			if ($file =~ /-1\./ && $prevFile !~ /-1\./) {
				print "rm $file\n";
			}
			if ($file =~ /Picasa/ && $prevFile !~ /Picasa/) {
				my $newF = $file;
				$newF =~ s/\\//g;
				print "rm \"$newF\"\n";
			}
			if ($file =~ /\(\d\)\./ && $prevFile !~ /\(\d\)\./) {
				my $newF = $file;
				$newF =~ s/\\//g;
				print "rm \"$newF\"\n";
			}
		}
	}


	## flickr compare
	elsif ($prevSize eq $size) {
		print "##- $size $date $file\n";
		print "##+ $prev $prevFile\n";
		my $file1 = '';
		my $file2 = '';
		if ($prevFile =~ /flickr/) {
			$file1 = $prevFile;
			$file2 = $file;
		}
		elsif ($file =~ /flickr/) {
			$file1 = $file;
			$file2 = $prevFile;
		}
		if ($file1 =~ /flickr/ && $file2 !~ /flickr/) {
			my $delfile = $file1;
			$file1 =~ s~.+/~~;
			$file2 =~ s~.+/~~;
			$file2 =~ s/#//g;
			$file2 =~ s/\\ 1//g;
			$file1 =~ s/_\d+(_o)?\././;
			$file1 =~ s/1\././;
			$file1 =~ s/^f//;
			$file2 =~ s/1\././;
			$file2 =~ s/[ ,\\]//g;
			if (uc($file1) eq uc($file2)) {
				print "rm \"$delfile\"\n";
			}
			else {
				print "###+ $file1\n###- $file2\n";
			}
		}
	}
	$prevFile = $file;
	$prev = "$size $date";
	$prevSize = $size;


	#print "$size == $date == $file\n";
}
