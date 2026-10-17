// Launcher-side loopback check. Usage: node check-endpoint.mjs <url> [log-prefix]
// Exit 0 when the URL is loopback (see loopback.mjs); otherwise one line on stderr, starting with
// the calling server's name (default local-llm), and exit 2.
import { isLoopbackEndpoint, loopbackError } from './loopback.mjs';

const [url = '', prefix = 'local-llm'] = process.argv.slice(2);
if (!isLoopbackEndpoint(url)) {
  console.error(`${prefix}: ${loopbackError(url)}`);
  process.exit(2);
}
