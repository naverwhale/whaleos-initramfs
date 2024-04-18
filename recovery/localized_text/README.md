# Recovery Image Localized Texts

This directory contains translations for the message strings shown in the
recovery installer UI.

## Steps to Modify/Add Messages
The message translation process works as follows:

1. If you make a code change that requires message changes, adjust the English
strings in `cros_recovery.grd`. This should be part of the CL that changes the
code, but it's OK to fix it up by itself if it was missed. After this is
reviewed & merged, the translation process can begin.<br>
NB: Do not hand edit the translation files (`cros_recovery_LANG.xtb`) as
any updates might be clobbered by our translators.

2. Copy your updated version of `cros_recovery.grd` to [Google's internal code
repository](https://cs.corp.google.com/piper///depot/google3/googleclient/chrome/transconsole_resources/strings/cros/cros_recovery.grd).
Once that CL merges, the translation process begins.

3. Wait until the actual translation process finishes (It can take a few weeks
though!).

4. Build all_xtbs target in the Google's internal code repository:
    ```shell
    # Make a g4 client if you haven't already.
    $ cd google3/googleclient/chrome/transconsole_resources
    $ blaze build all_xtbs
    ```

5. Find out where the blaze dumps the resulting `cros_recovery_LANG.xtb`
files. It will be visible by the blaze command log and possibly here:
`google3/blaze-genfiles/googleclient/chrome/transconsole_resources/strings/cros`.

6. Copy the resulting `cros_recovery_LANG.xtb` files which contain the
translated strings into your Chromium OS local branch. Make sure you get the
versions that use the correct fingerprinting algorithm to generate message IDs.

7. If you are adding any new languages, update the `cros_recovery.grd` file and
update the permissions of new files to 640 using `chmod`.

8. Create a code review that updates the corresponding files in this
directory. Do a sanity check to verify that your review only contains string
changes (i.e. no unexpected message ID changes).

9. (Optional, but recommended) Check updated images. Run `./make_images`
inside of the sdk and look at the various images under `screens/`.

10. (Optional, but recommended)  Build a recovery image with your translation
update change present and install the recovery image on a device to verify the
translated strings show up as intended.

11. Have your code change reviewed and submit it as usual.
