# Syslinux BLS Type 1 Entry Options Documentation

The minimum options that need to be specified in syslinux.cfg to boot a BLS type 1 entry are a default label and the line `BLS1 INCLUDE`. For example:

```
DEFAULT BLS001
BLS1 INCLUDE
```

The `BLS1 INCLUDE` directive takes an optional path to the directory containing the entry specifications. If not specified, the path defaults to `/loader/entries`.

The `BLS1 INCLUDE` directive scans the .conf files from the BLS type 1 directory and maps their fields to Syslinux's native fields as follows:

```
title => MENU LABEL
version => MENU LABEL
machine-id => unmapped
linux => LINUX
initrd => INITRD
efi => KERNEL
options => APPEND
devicetree => unmapped
architecture => unmapped
other => unmapped
```

* Syslinux does not support chain-loading efi files at this time. If both the efi and the linux fields are specified in an entry, the value from the linux field will be used.

* The `other` field has no reserved purpose. It is an extra field that can be used to store a custom sort value (e.g. a timestamp) or an optional display value.

After the .conf files are scanned, they are sorted first by machine-id, then by version, then by title. By default, the entries are sorted into descending order so that the newest entry will be first.

After sorting, the entries are auto-numbered with a three-digit number beginning with `001`. The auto-number is then prefixed with `BLS` to form a unique label name (i.e. `BLS001`, `BLS002`, etc.).

Any `*.conf` file whose name contains the word `default` will be sorted to the beginning of the list.

Any `*.conf` file whose name contains the word `rescue` will be sorted to the end of the list.

The following options are available for customizing the default behavior of the `BLS1 INCLUDE` directive. These options must be specified before the `BLS1 INCLUDE` directive they are meant to customize.

`BLS1 LABELF <format>`

A printf-style format specification for the auto-generated label names. Defaults to `BLS%03d`.

`BLS1 FORMAT <template>`

This template specifies how the menu labels should appear if either the `menu.c32` or the `vesamenu.c32` modules are loaded. Defaults to `$title ($version)`. The following variables are available for substitution:

```
$filename
$title
$version
$version0
$machine-id
$linux
$initrd
$efi
$options
$devicetree
$architecture
$other
```

* The `$version0` variable is a copy of the `$version` variable with the numeric fields padded with zeros to three places (e.g. `4.20` becomes `004.020`).

`BLS1 SORTBY <template>`

This template describes a hidden field that is used for sorting. Defaults to `$machine-id$version0$title`. Uses the same variables as the `BLS1 FORMAT` directive.

`BLS1 PINMIN <template> <value>`

If the template contains the specified value, the entry being processed will be sorted to the beginning of the list. The first space separates the template from the value to be matched, so this template cannot contain a space. The value is the remainder of the line beginning with the first non-space character. Defaults to `$filename default`. Uses the same variables as the `BLS1 FORMAT` directive.

`BLS1 PINMAX <template> <value>`

If the template contains the specified value, the entry being processed will be sorted to the end of the list. The first space separates the template from the value to be matched, so this template cannot contain a space. The value is the remainder of the line beginning with the first non-space character. Defaults to `$filename rescue`. Uses the same variables as the `BLS1 FORMAT` directive.

`BLS1 PADVER <count>`

The number of places the numeric fields of the `$version0` variable should be padded to. Defaults to `3`. Numeric fields are deliminated by a dash or a dot and contain only numbers.

`BLS1 ASCEND flag_val`

If `flag_val` is `0`, the non-pinned entries are sorted in descending order (this is the default). A `flag_val` of `1` causes the non-pinned entries to be sorted in ascending order.

`BLS1 SHWLBL flag_val`

If `flag_val` is `0`, the label (as defined by the `BLS1 LABELF` directive) is not shown (this is the default). A `flag_val` of `1` causes the label to be prefixed to the menu labels. For example:

```
DEFAULT 1
TIMEOUT 300
UI vesamenu.c32
MENU TITLE SYSLINUX 6.04
BLS1 SHWLBL 1
BLS1 LABELF %d
BLS1 FORMAT . $title ($version)
BLS1 INCLUDE /loader/entries
```

Might yield a menu list like the following:

```
1. Linux (4.20)
2. Linux (3.14)
3. Linux (2.71)
```
