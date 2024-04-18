# Copyright 2015 The ChromiumOS Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

SUBDIRS := $(patsubst %/,%,$(dir $(wildcard */Makefile)))
CHECK_TARGETS := $(patsubst %,%_check,$(SUBDIRS))

.PHONY: subdirs clean $(SUBDIRS) $(UNITTEST_TARGETS)

subdirs: $(SUBDIRS)

$(SUBDIRS):
	$(MAKE) -C $@

check: $(CHECK_TARGETS)

$(CHECK_TARGETS):
	$(MAKE) -C $(patsubst %_check,%,$@) check

clean:
	@$(foreach dir,$(SUBDIRS),$(MAKE) -C $(dir) clean;)
