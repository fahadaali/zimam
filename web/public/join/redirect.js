// Loaded by the 404 page. A static site cannot serve /join/<code> (the path form of an invite
// link), so the 404 page sends it to /join/#<code>, where the code stays in the browser.
import { legacyJoinRedirect } from "/app/lib/invites.js";

const target = legacyJoinRedirect(location.pathname);
if (target) location.replace(target);
