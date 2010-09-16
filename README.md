PGXN/Manager version 0.0.1
==========================

Database Configuration
----------------------

    plperl.use_strict = on
    plperl.on_init='use 5.12.0; use JSON::XS; use Email::Valid; use Data::Validate::URI; use SemVer;'

Installation
------------

To install this module, type the following:

    perl Build.PL
    ./Build
    ./Build test
    ./Build install

Copyright and Licence
---------------------

Copyright (c) 2010 David E. Wheeler. Some Rights Reserved.

This module is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.
