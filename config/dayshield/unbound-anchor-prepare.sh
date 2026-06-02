#!/bin/sh
# Prepare the unbound DNSSEC trust anchor before the resolver starts.
#
# /var/lib/unbound lives on the persistent state partition (DS_STATE) and so
# survives A/B rootfs updates. Re-running unbound-anchor on every boot (and
# again from installer-finalize.sh) could leave root.key holding two trust
# anchors for the root zone, making unbound fail to start with
# "trust anchor for '.' presented twice".
#
# To avoid that we:
#   1. bootstrap the anchor only when it is missing, and
#   2. self-heal a doubled-up anchor file - identical duplicate DS/DNSKEY
#      records, the signature of a file concatenated with itself across an
#      update - by regenerating it.
#
# A valid RFC 5011 key rollover legitimately holds several *distinct* DNSKEYs,
# so it never looks like a byte-identical duplicate and is left untouched.
set -u

ANCHOR=/var/lib/unbound/root.key
mkdir -p /var/lib/unbound

# Remove the anchor only when it contains byte-identical duplicate DS/DNSKEY
# records. Distinct rollover keys differ, so they never trigger this.
if [ -s "$ANCHOR" ] && \
   awk '/[ \t](DS|DNSKEY)[ \t]/ { if (++seen[$0] > 1) dup = 1 }
        END { exit(dup ? 0 : 1) }' "$ANCHOR"; then
    rm -f "$ANCHOR"
fi

# Bootstrap when missing/empty. unbound maintains RFC 5011 key rollovers itself
# once the file exists, so we deliberately do not re-run unbound-anchor on a
# healthy file.
if [ ! -s "$ANCHOR" ]; then
    if [ -x /usr/sbin/unbound-anchor ]; then
        /usr/sbin/unbound-anchor -a "$ANCHOR" || true
    elif [ -f /usr/share/dns/root.key ]; then
        cp /usr/share/dns/root.key "$ANCHOR" || true
    fi
fi

chown -R unbound:unbound /var/lib/unbound 2>/dev/null || true
