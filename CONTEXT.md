# PHP Apache Image Maintenance

This context defines the maintenance language for the PHP Apache image branches
and publication flow.

## Language

**PHP branch**:
A repository branch named for a PHP minor line, such as `php73`, `php74`, or
`php85`. These names are canonical and should not be replaced by policy labels.
_Avoid_: legacy branch, frozen branch, final branch

**Supported PHP branch**:
A PHP branch that participates in default maintenance commands and routine image
updates.
_Avoid_: active branch

**PHP7 branch**:
One of the existing PHP branches for PHP 7, currently `php73` and `php74`.
Maintenance that touches these branches should name them explicitly.
_Avoid_: legacy branch, frozen branch, final branch

**Source archive checksum**:
A SHA-256 checksum recorded next to a pinned source archive version used by the
image build.
_Avoid_: best-effort checksum

**Build-only CI**:
A CI run that builds the Dockerfile as a smoke test without tagging or
publishing an image.
_Avoid_: local image tag, unpublished release

**Bundled imagick**:
The PECL `imagick` extension included in the published image and linked against
the custom ImageMagick installation under `/usr/local`.
_Avoid_: optional imagick, downstream imagick

**Base-image compatibility cleanup**:
Image-build logic that removes or neutralizes broken configuration inherited
from the upstream base image when it prevents clean runtime startup.
_Avoid_: feature removal

**Shared file**:
A repository maintenance file that should be propagated from `latest` to PHP
branches because it is not branch-version-specific.
_Avoid_: common file
