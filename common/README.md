These files are shared between all initramfs environments.


fs-layout.txt
=============

Paths common to all initramfs environments that should be created before
installing files/etc...


gen_initramfs_list.sh
=====================

Create a flat listing of files for gen_init_cpio.

This comes directly from upstream Linux.  Please send changes there and keep
our copy unmodified.
https://git.kernel.org/cgit/linux/kernel/git/torvalds/linux.git/tree/scripts


gen_init_cpio.c
===============

Create a cpio archive from a flat listing.

This comes directly from upstream Linux.  Please send changes there and keep
our copy unmodified.
https://git.kernel.org/cgit/linux/kernel/git/torvalds/linux.git/tree/usr


init.sh
=======

Common runtime library used by /init scripts.


initramfs.mk
============

Common build logic used by specific Makefiles.


process-layout.py
=================

Helper script used by initramfs.mk to seed the staging dir from the fs layout.
