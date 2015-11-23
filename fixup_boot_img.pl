#!/bin/perl -w

use File::Copy;
use File::Path qw( make_path );

# This just edits a file in place
sub edit_file {
  my ($file, $fn) = @_;
  open my $fh, "<" , $file or die $!;
  @lines = <$fh>;
  for $_ (@lines) {
    &{$fn}($_);
  }
  close $fh;
  open $fh, ">", $file or die $!;
  print $fh @lines;
  close $fh;
}

# Either edit or add a key to a .prop file
sub ensure_key {
  my ($file, $key, $val) = @_;
  my $found=0;
  edit_file $file, sub {
    if ( /^$key=/ ) {
      s/^$key=.*/$key=$val/;
      $found=1;
      print "Fixing $key\n";
    };
  };
  if (! $found) {
    open $fh, ">>", $file or die $!;
    print "Adding $key\n";
    print $fh "$key=$val\n";
    close $fh;
  }
}

$CUTEBOOT_ROOT=$ENV{"CUTEBOOT_ROOT"};

$boot_img = $ARGV[0];

die "\$CUTEBOOT_ROOT not set/exported" unless $CUTEBOOT_ROOT;
die "\$CUTEBOOT_ROOT=$CUTEBOOT_ROOT but does not exist" unless -d $CUTEBOOT_ROOT;
die "No valid boot image provided" unless -e $boot_img;

make_path("$CUTEBOOT_ROOT/bootimg/ramdisk");
die "Can't mkdir \$CUTEBOOT_ROOT/bootimg/ramdisk" unless -d "$CUTEBOOT_ROOT/bootimg/ramdisk";
chdir("$CUTEBOOT_ROOT/bootimg");

print "Splitting $boot_img\n";
my $rebuild_boot_img_cmd;
open(my $split_fh, "$CUTEBOOT_ROOT/build/split_bootimg.pl $boot_img|") or die "Error with split_bootimg.pl\n$!";
my @split_output;
while (<$split_fh>) {
  tr/\0//d; # Remove NULL chars in output ... sad but true - probably fucks up if there's any UTF8 in the command line it spits out.
  push(@split_output, $_);
  chomp;
  $rebuild_boot_img_cmd = $_ if /^mkbootimg/; # Grab the rebuild command, we'll need it.
}
close $split_fh;

my $ramdisk;
if ($rebuild_boot_img_cmd =~ s/--ramdisk (.*?gz) /--ramdisk cuteboot-ramdisk.gz /g) {
  $ramdisk = $1;
} else {
  die "Couldn't find --ramdisk argument in split_bootimg.pl output:\n@split_output\ncmd:'$rebuild_boot_img_cmd'\n";
}
print "Got the rebuild command line $boot_img\n";

chdir("$CUTEBOOT_ROOT/bootimg/ramdisk");
system("rm -rf $CUTEBOOT_ROOT/bootimg/ramdisk/*");

print "Unzipping ramdisk: $ramdisk\n";
system("gzip -dc ../$ramdisk | cpio -id");

# Fixup the default.prop key/value pairs
print "Fixing default.prop:\n";
ensure_key("default.prop", "ro.secure", "0");
ensure_key("default.prop", "ro.debuggable", "1");
ensure_key("default.prop", "ro.zygote", "cuteboot");
ensure_key("default.prop", "ro.adb.secure", "0");
ensure_key("default.prop", "persist.sys.usb.config", "mtp,adb");

# Find the fstabs
print "Finding fstab\n";
@fstabs = glob "*fstab*";
$cacheline=0;
for my $f (@fstabs ) {
  open my $fh, "<", $f or die $!;
  while (<$fh>) {
    if (/\W\/cache\W/) {
      $cacheline++;
      $fstab=$f;
    }
  }
  close $fh;
}
warn "Too many fstab files ($cacheline) have a /cache entry - fix by hand" if $cacheline > 1;
warn "No fstab files have a /cache entry - fix by hand" if $cacheline == 0;
$fstab="fstab.hammerhead";

# Edit the fstab to make /cache /usr and remove nodev, nosuid and ro options
print "Fixing $fstab\n";
edit_file $fstab, sub {
  return unless /\s\/cache\s/ ;
  print "old /cache fstab entry:\n$_";
  s/\s\/cache\s/ \/usr /;
  s/[\s,]nodev[\s,]/,/;
  s/[\s,]nosuid[\s,]/,/;
  s/[\s,]ro[\s,]//;
  s/,+/,/g; # clean up commas
  s/,\s//g; # clean up trailing comma
  print "converted to /usr fstab entry:\n$_";
};
edit_file $fstab, sub {
  return unless /\s\/firmware\s/ ;
  print "old /firmware fstab entry:\n$_";
  s/[\s,]context=.*?[\s,]/,/;
  s/,+/,/g; # clean up commas
  s/,\s//g; # clean up trailing comma
  print "cleaned up /firmware fstab entry:\n$_";
};
# Set fstab to be world readable
chmod 0644, $fstab;

print "Fixing init.rc\n";
$found_bootanim=0;
edit_file "init.rc", sub {
  $found_bootanim = 1 if /^service\s+bootanim/;
  $found_bootanim = 0 if /^\s+$/;
  return unless $found_bootanim;
  s/^/#/; # comment out lines from "service bootanim" to the next blank line.
};

print "Copying init.cuteboot.rc, init.rc and init\n";
copy("$ENV{'CUTEBOOT_ROOT'}/build/init.cuteboot.rc", ".");
chmod 0750, "init.cuteboot.rc";
copy("$ENV{'ANDROID_PRODUCT_OUT'}/root/init", ".");

print "Making cuteboot-ramdisk.gz\n";
system("find . -print |cpio -H newc -o |gzip -9 > ../cuteboot-ramdisk.gz");

print "Creating new cuteboot.img\n";
chdir("$CUTEBOOT_ROOT/bootimg");
$rebuild_boot_img_cmd =~ s/boot.img.duplicate/cuteboot.boot.img/ || die "rebuild_boot_img_cmd didn't have boot.img.duplicate";
print "Rebuilding cuteboot.img like so:\n$rebuild_boot_img_cmd\n";
system($rebuild_boot_img_cmd);

print "\nMagic has happened - you have cuteboot.boot.img\n";
