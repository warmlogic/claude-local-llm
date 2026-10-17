// Launcher-side loopback check. Usage: node check-endpoint.mjs <url>
// Exit 0 when the URL is loopback (see loopback.mjs); otherwise one line on stderr and exit 2.
import { isLoopbackEndpoint, loopbackError } from './loopback.mjs';

const url = process.argv[2] ?? '';
if (!isLoopbackEndpoint(url)) {
  console.error(`local-llm: ${loopbackError(url)}`);
  process.exit(2);
}
