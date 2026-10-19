# Loads the adapter library and calls one of its entry points: perl run-adapter.pl <dylib> <symbol>
use strict;
use warnings;
use DynaLoader;
my ($library, $symbol) = @ARGV;
my $handle = DynaLoader::dl_load_file($library, 0) or die "load: " . DynaLoader::dl_error() . "\n";
my $entry = DynaLoader::dl_find_symbol($handle, $symbol) or die "symbol: " . DynaLoader::dl_error() . "\n";
DynaLoader::dl_install_xsub("main::entry", $entry);
entry();
