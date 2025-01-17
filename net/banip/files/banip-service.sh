#!/bin/sh
# banIP main service script - ban incoming and outgoing IPs via named nftables Sets
# Copyright (c) 2018-2023 Dirk Brenken (dev@brenken.org)
# This is free software, licensed under the GNU General Public License v3.

# (s)hellcheck exceptions
# shellcheck disable=all

ban_action="${1}"
ban_starttime="$(date "+%s")"
ban_funlib="/usr/lib/banip-functions.sh"
[ -z "$(command -v "f_system")" ] && . "${ban_funlib}"

# load config and set banIP environment
#
f_conf
f_log "info" "start banIP processing (${ban_action})"
f_log "debug" "f_system    ::: system: ${ban_sysver:-"n/a"}, version: ${ban_ver:-"n/a"}, memory: ${ban_memory:-"0"}, cpu_cores: ${ban_cores}"
f_genstatus "processing"
f_tmp
f_getfetch
f_getif
f_getdev
f_getuplink
f_mkdir "${ban_backupdir}"
f_mkfile "${ban_blocklist}"
f_mkfile "${ban_allowlist}"

# firewall check
#
if [ "${ban_action}" != "reload" ]; then
	if [ -x "${ban_fw4cmd}" ]; then
		cnt="0"
		while [ "${cnt}" -lt "30" ] && ! /etc/init.d/firewall status >/dev/null 2>&1; do
			cnt="$((cnt + 1))"
			sleep 1
		done
		if ! /etc/init.d/firewall status >/dev/null 2>&1; then
			f_log "err" "error in nft based firewall/fw4"
		fi
	else
		f_log "err" "no nft based firewall/fw4"
	fi
fi

# init nft namespace
#
if [ "${ban_action}" != "reload" ] || ! "${ban_nftcmd}" -t list set inet banIP allowlistv4MAC >/dev/null 2>&1; then
	if f_nftinit "${ban_tmpfile}".init.nft; then
		f_log "info" "initialize nft namespace"
	else
		f_log "err" "can't initialize nft namespace"
	fi
fi

# handle downloads
#
f_log "info" "start banIP download processes"
[ "${ban_allowlistonly}" = "1" ] && ban_feed="" || f_getfeed
[ "${ban_deduplicate}" = "1" ] && printf "\n" >"${ban_tmpfile}.deduplicate"

cnt="1"
for feed in allowlist ${ban_feed} blocklist; do
	# local feeds
	#
	if [ "${feed}" = "allowlist" ] || [ "${feed}" = "blocklist" ]; then
		for proto in 4MAC 6MAC 4 6; do
			[ "${feed}" = "blocklist" ] && wait
			(f_down "${feed}" "${proto}") &
			[ "${feed}" = "blocklist" ] || { [ "${feed}" = "allowlist" ] && { [ "${proto}" = "4MAC" ] || [ "${proto}" = "6MAC" ]; }; } && wait
			hold="$((cnt % ban_cores))"
			[ "${hold}" = "0" ] && wait
			cnt="$((cnt + 1))"
		done
		wait
		continue
	fi

	# external feeds
	#
	if ! json_select "${feed}" >/dev/null 2>&1; then
		f_log "info" "remove unknown feed '${feed}'"
		uci_remove_list banip global ban_feed "${feed}"
		uci_commit "banip"
		continue
	fi
	json_objects="url_4 rule_4 url_6 rule_6 flag"
	for object in ${json_objects}; do
		eval json_get_var feed_"${object}" '${object}' >/dev/null 2>&1
	done
	json_select ..

	# skip incomplete feeds
	#
	if { { [ -n "${feed_url_4}" ] && [ -z "${feed_rule_4}" ]; } || { [ -z "${feed_url_4}" ] && [ -n "${feed_rule_4}" ]; }; } ||
		{ { [ -n "${feed_url_6}" ] && [ -z "${feed_rule_6}" ]; } || { [ -z "${feed_url_6}" ] && [ -n "${feed_rule_6}" ]; }; } ||
		{ [ -z "${feed_url_4}" ] && [ -z "${feed_rule_4}" ] && [ -z "${feed_url_6}" ] && [ -z "${feed_rule_6}" ]; }; then
		f_log "info" "skip incomplete feed '${feed}'"
		continue
	fi

	# handle IPv4/IPv6 feeds with the same/single download URL
	#
	if [ "${feed_url_4}" = "${feed_url_6}" ]; then
		if [ "${ban_protov4}" = "1" ] && [ -n "${feed_url_4}" ] && [ -n "${feed_rule_4}" ]; then
			(f_down "${feed}" "4" "${feed_url_4}" "${feed_rule_4}" "${feed_flag}") &
			feed_url_6="local"
			wait
		fi
		if [ "${ban_protov6}" = "1" ] && [ -n "${feed_url_6}" ] && [ -n "${feed_rule_6}" ]; then
			(f_down "${feed}" "6" "${feed_url_6}" "${feed_rule_6}" "${feed_flag}") &
			hold="$((cnt % ban_cores))"
			[ "${hold}" = "0" ] && wait
			cnt="$((cnt + 1))"
		fi
		continue
	fi
	# handle IPv4/IPv6 feeds with separated download URLs
	#
	if [ "${ban_protov4}" = "1" ] && [ -n "${feed_url_4}" ] && [ -n "${feed_rule_4}" ]; then
		(f_down "${feed}" "4" "${feed_url_4}" "${feed_rule_4}" "${feed_flag}") &
		hold="$((cnt % ban_cores))"
		[ "${hold}" = "0" ] && wait
		cnt="$((cnt + 1))"
	fi
	if [ "${ban_protov6}" = "1" ] && [ -n "${feed_url_6}" ] && [ -n "${feed_rule_6}" ]; then
		(f_down "${feed}" "6" "${feed_url_6}" "${feed_rule_6}" "${feed_flag}") &
		hold="$((cnt % ban_cores))"
		[ "${hold}" = "0" ] && wait
		cnt="$((cnt + 1))"
	fi
done
wait
f_rmset
f_rmdir "${ban_tmpdir}"
f_genstatus "active"

# start domain lookup
#
f_log "info" "start banIP domain lookup"
cnt="1"
for list in allowlist blocklist; do
	(f_lookup "${list}") &
	hold="$((cnt % ban_cores))"
	[ "${hold}" = "0" ] && wait
	cnt="$((cnt + 1))"
done
wait

# end processing
#
if [ "${ban_mailnotification}" = "1" ] && [ -n "${ban_mailreceiver}" ] && [ -x "${ban_mailcmd}" ]; then
	(
		sleep ${ban_triggerdelay}
		f_mail
	) &
fi
json_cleanup
rm -rf "${ban_lock}"

# start detached log service (infinite loop)
#
f_monitor
