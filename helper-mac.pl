#!/usr/bin/perl
# G435 Helper for macOS: reads the Bluetooth battery level that macOS already knows
# and serves it to the G435 Launcher page at http://127.0.0.1:7435/battery
use strict; use warnings; use utf8;
use IO::Socket::INET; use JSON::PP;
binmode STDOUT, ':utf8';

my $PORT = 7435;
my $srv = IO::Socket::INET->new(LocalAddr=>'127.0.0.1', LocalPort=>$PORT, Listen=>8, ReuseAddr=>1, Proto=>'tcp')
  or die "\nПорт $PORT занят: помощник уже запущен в другом окне, или его держит другая программа.\n";

my ($cache, $cachedAt) = (undef, 0);
sub battery {
  return $cache if $cache && time - $cachedAt < 10;
  my $raw = `/usr/sbin/system_profiler -json SPBluetoothDataType 2>/dev/null`;
  my $j = eval { decode_json($raw) } || {};
  my $res = { ok=>JSON::PP::true, found=>JSON::PP::false, connected=>JSON::PP::false, percent=>undef, source=>'macOS Bluetooth' };
  for my $ctl (@{ $j->{SPBluetoothDataType} || [] }) {
    for my $kind (['device_connected', 1], ['device_not_connected', 0]) {
      for my $entry (@{ $ctl->{$kind->[0]} || [] }) {
        for my $name (keys %$entry) {
          next unless $name =~ /G435/i;
          my $d = $entry->{$name} || {};
          my $pct;
          for my $k (sort keys %$d) {
            next unless $k =~ /battery/i;
            if (($d->{$k} // '') =~ /(\d{1,3})\s*%/) { $pct = $1; last if $k =~ /Main/i; }
          }
          next if $res->{connected} && !$kind->[1];
          $res->{found} = JSON::PP::true;
          $res->{connected} = $kind->[1] ? JSON::PP::true : JSON::PP::false;
          $res->{name} = $name;
          $res->{percent} = defined $pct ? $pct + 0 : undef;
          $res->{address} = $d->{device_address} if $d->{device_address};
          $res->{firmware} = $d->{device_firmwareVersion} if $d->{device_firmwareVersion};
        }
      }
    }
  }
  ($cache, $cachedAt) = ($res, time);
  return $res;
}

# Every Bluetooth / Apple accessory with a battery that macOS knows about
my ($devs, $devsAt) = (undef, 0);
sub kind_of {
  my ($t, $n) = (lc($_[0] // ''), lc($_[1] // ''));
  return 'mouse' if $t =~ /mouse/ || $n =~ /mouse|mx master|mx anywhere/;
  return 'keyboard' if $t =~ /keyboard/ || $n =~ /keyboard|keys/;
  return 'trackpad' if $t =~ /trackpad/ || $n =~ /trackpad/;
  return 'gamepad' if $t =~ /gamepad|game|joystick/ || $n =~ /controller|dualsense|xbox/;
  return 'headset' if $t =~ /head|ear|speaker|audio/ || $n =~ /airpods|buds|head|g435|beats/;
  return 'device';
}
sub devices {
  return $devs if $devs && time - $devsAt < 5;
  my @out; my %seen;
  my $j = eval { decode_json(`/usr/sbin/system_profiler -json SPBluetoothDataType 2>/dev/null`) } || {};
  for my $ctl (@{ $j->{SPBluetoothDataType} || [] }) {
    for my $kind (['device_connected', 1], ['device_not_connected', 0]) {
      for my $entry (@{ $ctl->{$kind->[0]} || [] }) {
        for my $name (keys %$entry) {
          my $d = $entry->{$name} || {};
          my (%b, $main);
          for my $k (keys %$d) {
            next unless $k =~ /battery/i && ($d->{$k} // '') =~ /(\d{1,3})\s*%/;
            my $v = $1 + 0; my $part = $k =~ /left/i ? 'L' : $k =~ /right/i ? 'R' : $k =~ /case/i ? 'case' : 'main';
            $b{$part} = $v;
          }
          next unless %b;
          $main = $b{main} // (defined $b{L} || defined $b{R} ? (sort { $a <=> $b } grep defined, $b{L}, $b{R})[0] : $b{case});
          my %x = (name=>$name, percent=>$main, connected=>$kind->[1] ? JSON::PP::true : JSON::PP::false,
                   kind=>kind_of($d->{device_minorType}, $name), source=>'macOS Bluetooth');
          $x{address} = $d->{device_address} if $d->{device_address};
          $x{firmware} = $d->{device_firmwareVersion} if $d->{device_firmwareVersion};
          $x{parts} = join(' ', map { "$_ $b{$_}%" } grep { $_ ne 'main' } sort keys %b) if grep { $_ ne 'main' } keys %b;
          push @out, \%x; $seen{lc $name} = 1;
        }
      }
    }
  }
  # Apple keyboards, mice and trackpads (also over USB) report BatteryPercent in the I/O registry
  my $io = `/usr/sbin/ioreg -r -l -k BatteryPercent 2>/dev/null` // '';
  for my $blk (split /\n(?=\+-o )/, $io) {
    my ($pn) = $blk =~ /"Product"\s*=\s*"([^"]+)"/; my ($pc) = $blk =~ /"BatteryPercent"\s*=\s*(\d+)/;
    next unless $pn && defined $pc && !$seen{lc $pn}++;
    my ($fl) = $blk =~ /"BatteryStatusFlags"\s*=\s*(\d+)/;
    push @out, { name=>$pn, percent=>$pc+0, connected=>JSON::PP::true, kind=>kind_of('', $pn), source=>'macOS',
                 charging=>(defined $fl && ($fl & 2)) ? JSON::PP::true : JSON::PP::false };
  }
  ($devs, $devsAt) = ({ ok=>JSON::PP::true, platform=>'mac', devices=>\@out }, time);
  return $devs;
}

# Latest official firmware, read from Logitech's own support page (cached for 6 hours)
my $FW_PAGE = 'https://support.logi.com/hc/en-ca/articles/33655346235543-Logitech-G435-LIGHTSPEED-Wireless-Gaming-Headset-Update-Tool';
my ($fw, $fwAt) = (undef, 0);
sub firmware {
  return $fw if $fw && time - $fwAt < 6*3600;
  my $html = `/usr/bin/curl -fsSL -m 20 -A 'Mozilla/5.0 (Macintosh)' '$FW_PAGE' 2>/dev/null` // '';
  my $r = { ok=>JSON::PP::true, platform=>'mac', canInstall=>JSON::PP::false, page=>$FW_PAGE };
  if ($html =~ m{(https://download01\.logi\.com/[^"'\s<>()]*?G435Update_(\d+(?:\.\d+){2,3})\.exe)}i) { $r->{latest}=$2; $r->{url}=$1 }
  if ($html =~ /Last Update:?\s*(?:<[^>]*>\s*)*(\d{4}-\d{2}-\d{2})/i) { $r->{date}=$1 }
  ($fw, $fwAt) = ($r, time) if $r->{latest};
  return $r;
}

my $CORS = "Access-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, OPTIONS\r\n"
         . "Access-Control-Allow-Headers: *\r\nAccess-Control-Allow-Private-Network: true\r\n";

print "\n  G435 Helper работает.\n  Не закрывай это окно, пока пользуешься лаунчером.\n  Остановить: Control+C\n\n";
my $b = battery();
if (!$b->{found})          { print "  G435 пока не найден в Bluetooth. Подключи наушники по Bluetooth.\n\n" }
elsif (!$b->{connected})   { print "  G435 есть в Bluetooth, но сейчас не подключены.\n\n" }
elsif (defined $b->{percent}) { print "  $b->{name}: $b->{percent}%\n\n" }
else                        { print "  $b->{name} подключены, но macOS не получает от них заряд.\n\n" }

while (my $c = $srv->accept) {
  $c->autoflush(1);
  my $req = <$c> // '';
  while (defined(my $l = <$c>)) { last if $l =~ /^\r?\n$/ }
  if ($req =~ /^OPTIONS/) {
    print $c "HTTP/1.1 204 No Content\r\n${CORS}Content-Length: 0\r\nConnection: close\r\n\r\n";
  } else {
    my $data = $req =~ m{^GET /firmware} ? firmware() : $req =~ m{^GET /devices} ? devices() : battery();
    my $body = JSON::PP->new->utf8->canonical->encode($data);
    print $c "HTTP/1.1 200 OK\r\n${CORS}Content-Type: application/json; charset=utf-8\r\nCache-Control: no-store\r\n"
           . "Content-Length: " . length($body) . "\r\nConnection: close\r\n\r\n$body";
  }
  close $c;
}
