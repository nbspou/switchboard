/*
Polyverse Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Authors:
  Jan Boon <jan.boon@kaetemi.be>
  Claude Opus 5.5 <noreply@anthropic.com>
*/

/// Rejection statuses for peers. Internal to the package; not exported.
library;

import '../status.dart';

/// [code] with a short generic reason ('not found', 'permission
/// denied', ...), for rejections sent to peers.
///
/// Rejections must not describe the mesh (instance ids, internal
/// endpoints, resolver state) to a peer that may be untrusted; the details
/// belong in the local log. See the wiki page "Polyverse Switchboard Addressing and
/// Dispatch", section "Dispatch of incoming channels".
Status genericStatus(StatusCode code) => Status.of(
  code,
  code.name.replaceAllMapped(RegExp('[A-Z]'), (m) => ' ${m[0]!.toLowerCase()}'),
);
