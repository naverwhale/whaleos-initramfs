#!/usr/bin/env python3
# Copyright 2015 The ChromiumOS Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

"""Helper tools related to the layout text file.

First create a directory with the paths in it:
$ %(progs)s make common/fs-layout.txt stagedir/

Then create a reduced layout for later inclusion:
$ %(progs)s filter common/fs-layout.txt new-layout.txt
"""

import argparse
import errno
import os
import sys


def symlink(src, dst):
    """Like os.symlink, but handle existing errors"""
    try:
        os.symlink(src, dst)
        return
    except OSError as e:
        if e.errno != errno.EEXIST:
            raise
        # Assume the symlink has changed to make our lives simple.
        os.unlink(dst)
        os.symlink(src, dst)


def ProcessLayout(layout):
    """Yield each valid line in |layout| as a tuple of each element"""
    # The number of elements expected for each object type.
    valid_lens = {
        "file": (6, 7),
        "dir": (5,),
        "nod": (8,),
        "slink": (6,),
        "pipe": (5,),
        "sock": (5,),
    }

    with open(layout, encoding="utf-8") as f:
        for line in f:
            line = line.split("#", 1)[0].strip()
            if not line:
                continue

            elements = line.split()

            etype = elements[0]
            if etype not in valid_lens:
                raise ValueError(
                    'Invalid line: unknown type "%s":\n%s' % (etype, line)
                )

            valid_len = valid_lens[etype]
            if len(elements) not in valid_len:
                raise ValueError(
                    "Invalid line: wanted %r elements; got %i:\n%s"
                    % (valid_len, len(elements), line)
                )

            yield elements


def GetParser():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "mode", choices=("make", "filter"), help="operation to perform"
    )
    parser.add_argument("layout", help="path to the filesystem layout file")
    parser.add_argument("output", help="path to operate on")
    return parser


def main(argv):
    parser = GetParser()
    opts = parser.parse_args(argv)

    if opts.mode == "make":
        # Create all the requested directories/files in the output directory.
        # These paths are needed so we can install all files into the right
        # layout w/out creating conflicts (e.g. /usr being a dir or a symlink).
        for elements in ProcessLayout(opts.layout):
            etype = elements.pop(0)
            try:
                if etype == "dir":
                    path, mode, uid, gid = elements
                    assert ("0", "0") == (uid, gid)
                    mode = int(mode, 8)
                    path = os.path.join(opts.output, path.lstrip("/"))
                    os.makedirs(path, exist_ok=True)
                    os.chmod(path, mode)
                elif etype == "slink":
                    path, target, mode, uid, gid = elements
                    mode = int(mode, 8)
                    assert ("0", "0", 0o755) == (uid, gid, mode)
                    path = os.path.join(opts.output, path.lstrip("/"))
                    os.makedirs(os.path.dirname(path), exist_ok=True)
                    symlink(target, path)
            except Exception:
                print("While processing line: %s %s" % (etype, elements))
                raise

    elif opts.mode == "filter":
        # Filter out all the paths that 'make' above created.  The stuff that is
        # left often requires root access (which we don't have), but the cpio
        # gen tool can take care of this for us.
        with open(opts.output, "a", encoding="utf-8") as f:
            for elements in ProcessLayout(opts.layout):
                if elements[0] not in ("dir", "slink"):
                    f.write(" ".join(elements) + "\n")


if __name__ == "__main__":
    main(sys.argv[1:])
