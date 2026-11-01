#!/bin/ksh -p
# SPDX-License-Identifier: CDDL-1.0
#
# This file and its contents are supplied under the terms of the
# Common Development and Distribution License ("CDDL"), version 1.0.
# You may only use this file in accordance with the terms of version
# 1.0 of the CDDL.
#
# A full copy of the text of the CDDL should have accompanied this
# source.  A copy of the CDDL is also available via the Internet at
# https://opensource.org/license/CDDL-1.0.
#

. $STF_SUITE/include/libtest.shlib

#
# DESCRIPTION:
#	A rollback must not deadlock with page faults and writeback on
#	files of the filesystem that is rolled back.
#
# STRATEGY:
#	1. Create three files and snapshot the filesystem.
#	2. In the background, keep faulting in the first file after dropping
#	   its cached pages, keep touching random pages of the second one,
#	   and keep dirtying the third one and writing it back.
#	3. Once all of them are running, roll back to the snapshot over and
#	   over, and require each rollback to finish within two minutes.
#

verify_runnable "global"

typeset fs=$TESTPOOL/$TESTFS
typeset snap=$fs@mmap_rollback_deadlock
typeset base=mmap_rollback_deadlock
typeset log=$TEST_BASE_DIR/$base
typeset -i runtime=30
typeset pids=""
typeset rpid=""
typeset hung=""

function running # pid
{
	[[ -d /proc/$1 ]] && [[ $(awk '{print $3}' /proc/$1/stat) != Z ]]
}

function wait_exit # pid seconds
{
	typeset -i n=0

	while running $1 && ((n++ < $2 * 10)); do
		sleep 0.1
	done
	! running $1
}

function cleanup
{
	typeset pid

	[[ -n $pids ]] && kill $pids 2>/dev/null
	# Waiting for tasks stuck in a deadlock, or cleaning up after them,
	# would hang as well.
	[[ -n $hung ]] && return
	for pid in $rpid $pids; do
		wait_exit $pid 60 || return
	done
	wait
	datasetexists $snap && destroy_dataset $snap
	rm -f $TESTDIR/$base.* $log.*
}

log_assert "A rollback must not deadlock with page faults and writeback"
log_onexit cleanup

log_must dd if=/dev/urandom of=$TESTDIR/$base.cold bs=1M count=16
log_must dd if=/dev/urandom of=$TESTDIR/$base.hot bs=1M count=16
log_must dd if=/dev/urandom of=$TESTDIR/$base.dirty bs=1M count=8
log_must zfs snapshot $snap

for mode in cold hot dirty; do
	mmap_fault_loop $mode $TESTDIR/$base.$mode >$log.$mode 2>&1 &
	pids="$pids $!"
done
for mode in cold hot dirty; do
	typeset -i n=0
	until grep -q ready $log.$mode; do
		((n++ < 600)) || log_fail "mmap_fault_loop $mode did not start"
		sleep 0.1
	done
done

typeset -i n=0
SECONDS=0
while ((SECONDS < runtime)); do
	zfs rollback $snap >$log.rollback 2>&1 &
	rpid=$!
	if ! wait_exit $rpid 120; then
		hung=$rpid
		for pid in $rpid $pids; do
			log_note "$pid: $(cat /proc/$pid/stack 2>/dev/null)"
		done
		log_fail "rollback $n did not finish within two minutes"
	fi
	wait $rpid || log_fail "rollback $n failed: $(<$log.rollback)"
	((n++))
done

kill $pids
for pid in $pids; do
	if ! wait_exit $pid 60; then
		hung=$pid
		log_fail "mmap_fault_loop $pid did not stop"
	fi
	wait $pid || log_fail "mmap_fault_loop $pid failed: $(cat $log.*)"
done
pids=""

log_pass "$n rollbacks did not deadlock with page faults and writeback"
