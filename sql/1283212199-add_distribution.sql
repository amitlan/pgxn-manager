-- sql/1282692433-add_distribution.sql SQL Migration

CREATE OR REPLACE FUNCTION setup_meta(
    IN  nick        LABEL,
    IN  sha1        TEXT,
    IN  json        TEXT,
    OUT name        CITEXT,
    OUT VERSION     SEMVER,
    OUT relstatus   RELSTATUS,
    OUT abstract    TEXT,
    OUT description TEXT,
    OUT provided    TEXT[][],
    OUT tags        CITEXT[],
    OUT json        TEXT
) LANGUAGE plperl IMMUTABLE AS $$
    my $idx_meta  = { owner => shift, sha1 => shift };
    my $dist_meta = JSON::XS::decode_json shift;

    # Check required keys.
    for my $key qw(name version license maintainer abstract) {
        $idx_meta->{$key} = $dist_meta->{$key} or elog(
            ERROR, qq{Metadata is missing the required “$key” key}
        );
    }

    # Grab optional fields.
    for my $key qw(description tags no_index prereqs provides release_status resources) {
        $idx_meta->{$key} = $dist_meta->{$key} if exists $dist_meta->{$key};
    }

    # Set default release status.
    $idx_meta->{release_status} ||= 'stable';

    # Normalize version string.
    $idx_meta->{version} = SemVer->declare($idx_meta->{version})->normal;

    # Normalize "prereq" version strings.
    if (my $prereqs = $idx_meta->{prereqs}) {
        for my $phase (values %{ $prereqs }) {
            for my $type ( values %{ $phase }) {
                for my $prereq (keys %{ $type }) {
                    $type->{$prereq} = SemVer->declare($type->{$prereq})->normal;
                }
            }
        }
    }

    if (my $provides = $idx_meta->{provides}) {
        # Normalize "provides" version strings.
        for my $ext (values %{ $provides }) {
            $ext->{version} = SemVer->declare($ext->{version})->normal;
        }
    } else {
        # Default to using the distribution name as the extension.
        $idx_meta->{provides} = {
            $idx_meta->{name} => { version => $idx_meta->{version} }
        };
    }

    # Recreate the JSON.
    my $encoder = JSON::XS->new->space_after->allow_nonref->indent->canonical;
    my $json = "{\n   " . join(",\n   ", map {
        $encoder->indent( $_ ne 'tags');
        my $v = $encoder->encode($idx_meta->{$_});
        chomp $v;
        $v =~ s/^(?![[{])/   /gm if ref $idx_meta->{$_} && $_ ne 'tags';
        qq{"$_": $v}
    } grep {
        defined $idx_meta->{$_}
    } qw(
        name abstract description version maintainer release_status owner sha1
        license prereqs provides tags resources generated_by no_index
        meta-spec
    )) . "\n}\n";

    # Return the distribution metadata.
    my $p = $idx_meta->{provides};
    return {
        name        => $idx_meta->{name},
        version     => $idx_meta->{version},
        relstatus   => $idx_meta->{release_status},
        abstract    => $idx_meta->{abstract},
        description => $idx_meta->{description},
        json        => $json,
        tags        => encode_array_literal( $idx_meta->{tags} || []),
        provided    => encode_array_literal([
            map { [ $_ => $p->{$_}{version} ] } sort keys %{ $p }
        ]),
    };
$$;

-- Disallow end-user from using this function.
REVOKE ALL ON FUNCTION setup_meta(LABEL, TEXT, TEXT) FROM PUBLIC;

CREATE OR REPLACE FUNCTION record_ownership(
    nick  LABEL,
    exts  TEXT[]
) RETURNS BOOLEAN LANGUAGE plpgsql AS $$
DECLARE
    owned    CITEXT[];
    is_owner BOOLEAN;
BEGIN
    -- See what we own already.
    SELECT array_agg(e.name), bool_and(e.owner = nick OR co.nickname IS NOT NULL)
      INTO owned, is_owner
      FROM extensions e
      LEFT JOIN coowners co ON e.name = co.extension AND co.nickname = nick
     WHERE e.name = ANY(exts);

    -- If nick is not owner or cowowner of any extension, return false.
    IF NOT is_owner THEN RETURN FALSE; END IF;

    IF owned IS NULL OR array_length(owned, 1) <> array_length(exts, 1) THEN
        -- There are some other extensions. Make nick the owner.
        INSERT INTO extensions (name, owner)
        SELECT e, nick
          FROM unnest(exts) AS e
         WHERE e <> ALL(COALESCE(owned, '{}'));
    END IF;

    -- Good to go.
    RETURN TRUE;
END;
$$;

-- Disallow end-user from using this function.
REVOKE ALL ON FUNCTION record_ownership(LABEL, TEXT[]) FROM PUBLIC;

CREATE OR REPLACE FUNCTION add_distribution(
    nick LABEL,
    sha1 TEXT,
    meta TEXT
) RETURNS TABLE (
    template TEXT,
    subject  TEXT,
    json     TEXT
) LANGUAGE plpgsql STRICT SECURITY DEFINER AS $$
/*

    % SELECT * FROM add_distribution('theory', 'ebf381e2e1e5767fb068d1c4423a9d9f122c2dc6', '{
        "name": "pair",
        "version": "0.0.01",
        "license": "postgresql",
        "maintainer": "theory",
        "abstract": "Ordered pair",
        "tags": ["ordered pair", "key value"],
        "provides": {
            "pair": { "file": "pair.sql.in", "version": "0.02.02" },
            "trip": { "file": "trip.sql.in", "version": "0.02.01" }
        },
        "release_status": "testing"
    }');
    
       template   │   subject    │                                 json                                 
    ──────────────┼──────────────┼──────────────────────────────────────────────────────────────────────
     meta         │ pair         │ {                                                                   ↵
                  │              │    "name": "pair",                                                  ↵
                  │              │    "abstract": "Ordered pair",                                      ↵
                  │              │    "version": "0.0.1",                                              ↵
                  │              │    "maintainer": "theory",                                          ↵
                  │              │    "release_status": "testing",                                     ↵
                  │              │    "owner": "theory",                                               ↵
                  │              │    "sha1": "ebf381e2e1e5767fb068d1c4423a9d9f122c2dc6",              ↵
                  │              │    "license": "postgresql",                                         ↵
                  │              │    "provides": {                                                    ↵
                  │              │       "pair": {                                                     ↵
                  │              │          "file": "pair.sql.in",                                     ↵
                  │              │          "version": "0.2.2"                                         ↵
                  │              │       },                                                            ↵
                  │              │       "trip": {                                                     ↵
                  │              │          "file": "trip.sql.in",                                     ↵
                  │              │          "version": "0.2.1"                                         ↵
                  │              │       }                                                             ↵
                  │              │    },                                                               ↵
                  │              │    "tags": ["ordered pair", "key value"]                            ↵
                  │              │ }                                                                   ↵
                  │              │ 
     by-dist      │ pair         │ {                                                                   ↵
                  │              │    "name": "pair",                                                  ↵
                  │              │    "releases": {                                                    ↵
                  │              │       "testing": ["0.0.1"]                                          ↵
                  │              │    }                                                                ↵
                  │              │ }                                                                   ↵
                  │              │ 
     by-extension │ pair         │ {                                                                   ↵
                  │              │    "extension": "pair",                                             ↵
                  │              │    "latest": "testing",                                             ↵
                  │              │    "testing":  { "dist": "pair", "version": "0.0.1" },              ↵
                  │              │    "versions": {                                                    ↵
                  │              │       "0.2.2": [                                                    ↵
                  │              │          { "dist": "pair", "version": "0.0.1", "status": "testing" }↵
                  │              │       ]                                                             ↵
                  │              │    }                                                                ↵
                  │              │ }                                                                   ↵
                  │              │ 
     by-extension │ trip         │ {                                                                   ↵
                  │              │    "extension": "trip",                                             ↵
                  │              │    "latest": "testing",                                             ↵
                  │              │    "testing":  { "dist": "pair", "version": "0.0.1" },              ↵
                  │              │    "versions": {                                                    ↵
                  │              │       "0.2.1": [                                                    ↵
                  │              │          { "dist": "pair", "version": "0.0.1", "status": "testing" }↵
                  │              │       ]                                                             ↵
                  │              │    }                                                                ↵
                  │              │ }                                                                   ↵
                  │              │ 
     by-owner     │ theory       │ {                                                                   ↵
                  │              │    "nickname": "theory",                                            ↵
                  │              │    "name": "",                                                      ↵
                  │              │    "email": "theory@pgxn.org",                                      ↵
                  │              │    "releases": {                                                    ↵
                  │              │       "pair": {                                                     ↵
                  │              │          "testing": ["0.0.1"]                                       ↵
                  │              │       }                                                             ↵
                  │              │    }                                                                ↵
                  │              │ }                                                                   ↵
                  │              │ 
     by-tag       │ ordered pair │ {                                                                   ↵
                  │              │    "tag": "ordered pair",                                           ↵
                  │              │    "releases": {                                                    ↵
                  │              │       "pair": {                                                     ↵
                  │              │          "testing": [ "0.0.1" ]                                     ↵
                  │              │       }                                                             ↵
                  │              │    }                                                                ↵
                  │              │ }                                                                   ↵
                  │              │ 
     by-tag       │ key value    │ {                                                                   ↵
                  │              │    "tag": "key value",                                              ↵
                  │              │    "releases": {                                                    ↵
                  │              │       "pair": {                                                     ↵
                  │              │          "testing": [ "0.0.1" ]                                     ↵
                  │              │       }                                                             ↵
                  │              │    }                                                                ↵
                  │              │ }                                                                   ↵
                  │              │ 

Creates a new distribution, returning all of the JSON that needs to be written
to the mirror in order for the distribution to be indexed. The nickname of the
uploading user (owner) must be passed as the first argument. The SHA1 of the
distribution file must be passed as the second argument. All other metadata is
parsed from the JSON string, which should contain the complete contents of the
distribution's `META.json` file. The required keys in the JSON metadata are:

name
: The name of the extension.

version
: The extension version string. Will be normalized by `clean_semver()`.

license
: The license or licenses.

maintainer
: The distribution maintainer or maintainers.

abstract
: Short description of the distribution.

See the [PGXN Meta Spec](http://github.com/theory/pgxn/wiki/PGXN-Meta-Spec)
for the complete list of specified keys.

With this data, `add_distribution()` does the following things:

* Parses the JSON string and validates that all required keys are present.
  Throws an exception if they're not.

* Creates a new metadata structure and stores all the required and many of the
  optional meta spec keys, as well as the SHA1 of the distribution file and
  the owner's nickname.

* Normalizes all of the version numbers found in the metadata into compliant
  semantic version strings. See
  [`SemVer->normal`](http://search.cpan.org/dist/SemVer/lib/SemVer.pm#declare)
  for details on how non-compliant version strings are converted. Versions
  that cannot be normalized will trigger an exception.

* Specifies that the provided extension is the same as the distribution name
  and version if no "provides" metadata is present in the distribution
  metadata.

* Validates that the uploading user is owner or co-owner of all provided
  extensions. If no one is listed as owner of one or more included extensions,
  the user will be assigned ownership. If the user is not owner or co-owner of
  any included extensions, an exception will be thrown.

* Inserts the distribution data into the `distributions` table.

* Inserts records for all included exentions into the
  `distribution_extensions` table.

* Inserts records for all associated tags into the `distribution_tags` table.

Once all this work is done, `add_distribution()` returns a relation with the
following columns:

template
: Name of a mirror URI template.

subject
: The subject of the metadata to be written, such as the name of a
  distribution, extension, owner, or tag.

json
: The JSON-formatted metadata for the subject, which the application should
  write to the fie specified by the template.

*/
DECLARE
    -- Parse and normalize the metadata.
    distmeta record;
BEGIN
    distmeta  := setup_meta(nick, sha1, meta);
    -- Check permissions for provided extensions.
    IF NOT record_ownership(nick, ARRAY(
        SELECT distmeta.provided[i][1] FROM generate_subscripts(distmeta.provided, 1) AS i
    )) THEN
        RAISE EXCEPTION 'User “%” does not own all provided extensions', nick;
    END IF;

    -- Create the distribution.
    BEGIN
        INSERT INTO distributions (name, version, relstatus, abstract, description, sha1, owner, meta)
        VALUES (distmeta.name, distmeta.version, COALESCE(distmeta.relstatus, 'stable'),
                distmeta.abstract, COALESCE(distmeta.description, ''), sha1, nick, distmeta.json);
    EXCEPTION WHEN unique_violation THEN
       RAISE EXCEPTION 'Distribution % % already exists', distmeta.name, distmeta.version;
    END;

    -- Record the extensions in this distribution.
    BEGIN
        INSERT INTO distribution_extensions (extension, ext_version, distribution, dist_version)
        SELECT distmeta.provided[i][1], distmeta.provided[i][2], distmeta.name, distmeta.version
          FROM generate_subscripts(distmeta.provided, 1) AS i;
    EXCEPTION WHEN unique_violation THEN
       IF array_length(distmeta.provided, 1) = 1 THEN
           RAISE EXCEPTION 'Extension % version % already exists',
               distmeta.provided[1][1], distmeta.provided[1][2];
       ELSE
           distmeta.provided := ARRAY(
               SELECT distmeta.provided[i][1] || ' ' || distmeta.provided[i][2]
                 FROM generate_subscripts(distmeta.provided, 1) AS i
           );
           RAISE EXCEPTION 'One or more versions of the provided extensions already exist:
  %', array_to_string(distmeta.provided, '
  ');
       END IF;
    END;

    -- Record the tags for this distribution.
    INSERT INTO distribution_tags (distribution, version, tag)
    SELECT DISTINCT distmeta.name, distmeta.version, tag
      FROM unnest(distmeta.tags) AS tag;

    RETURN QUERY
        SELECT 'meta'::TEXT, distmeta.name::TEXT, distmeta.json
    UNION
        SELECT 'by-dist', distmeta.name::TEXT, by_dist_json(distmeta.name)
    UNION
        SELECT 'by-extension', * FROM by_extension_json(distmeta.name, distmeta.version)
    UNION
        SELECT 'by-owner', LOWER(nick), by_owner_json(nick)
    UNION
        SELECT 'by-tag', * FROM by_tag_json(distmeta.name, distmeta.version)
    ;
END;
$$;