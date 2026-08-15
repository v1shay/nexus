type Status = "verified" | "planning" | "unreliable" | "blocked" | "not-working";

type Evidence = {
  title: string;
  status: Status;
  tool: string;
  model: string;
  prompt: string;
  latency: string;
  outcome: string;
  receipt: string;
  note?: string;
};

const evidence: Evidence[] = [
  {
    title: "YouTube playback — first real pass",
    status: "unreliable",
    tool: "browser.play_youtube",
    model: "gpt-oss:latest",
    prompt: "Put on a short lo-fi coding mix and make it fill the screen.",
    latency: "16.60 s",
    outcome: "Selected a visible video, entered YouTube fullscreen, and reported playing.",
    receipt:
      '{"state":"media_playing","transcript":"Put on a short lo-fi coding mix and make it fill the screen.","result":"YouTube is playing in the frontmost Nexus browser window."}',
    note: "Initial model-only plan selected fullscreen without playback; deterministic intent routing fixed that gap.",
  },
  {
    title: "YouTube playback — repeat pass",
    status: "unreliable",
    tool: "browser.play_youtube",
    model: "gpt-oss:latest",
    prompt: "Play a calm instrumental playlist and show it full screen.",
    latency: "25.90 s",
    outcome: "Started a real YouTube watch URL and returned a media-playing receipt.",
    receipt:
      '{"state":"media_playing","result":"Browser task playing.","tabs":["https://www.youtube.com/watch?v=FS93cEWcwQA&list=RDFS93cEWcwQA&start_radio=1"]}',
    note: "The query-tail normalizer was fixed immediately after this run.",
  },
  {
    title: "Headless request concurrency",
    status: "verified",
    tool: "Nexus headless control",
    model: "gpt-oss:latest",
    prompt: "Put on a simple ambient track.",
    latency: "0.33 s",
    outcome: "A second prompt correctly received a busy response while the first playback request was active.",
    receipt:
      '{"ok":false,"result":{"state":"busy"},"error":"A Nexus prompt is already running. Wait for it to finish or cancel it before starting another request."}',
  },
  {
    title: "NexCLI managed worker",
    status: "verified",
    tool: "NexCLI host",
    model: "gpt-oss:latest",
    prompt: "— service health check —",
    latency: "< 1 s",
    outcome: "The persistent headless worker is live and ready.",
    receipt:
      '{"live":"true","runtime":"managed NexCLI","state":"ready","detail":""}',
  },
  {
    title: "Messages triage",
    status: "blocked",
    tool: "messages.* (7 registered actions)",
    model: "gpt-oss:latest",
    prompt: "Scan the recent conversations from Vishay and tell me anything I need to respond to.",
    latency: "Not a valid result",
    outcome: "Not counted: a cancelled browser task contaminated this attempt. Receipt isolation and browser cancellation were fixed afterward; a clean real-message run still requires durable macOS grants.",
    receipt:
      '{"full_disk_access_messages":false,"permission_host_durable":false}',
  },
  {
    title: "Durable macOS permissions",
    status: "blocked",
    tool: "accessibility / screen recording / microphone / Messages",
    model: "system diagnostic",
    prompt: "— permission-host diagnostic —",
    latency: "0.66 s",
    outcome: "Blocked by the current ad-hoc build identity, not by an automation routing failure.",
    receipt:
      '{"durable":"false","message":"Nexus is ad-hoc or unidentified signed. Permission onboarding requires a certificate-backed Nexus signing lineage (Apple Development, Developer ID, or Xcode’s persistent local development identity)."}',
  },
  {
    title: "Permission smoke test",
    status: "blocked",
    tool: "macOS privacy services",
    model: "system diagnostic",
    prompt: "— runtime permission smoke —",
    latency: "0.17 s",
    outcome: "No relevant privacy grant is currently available to this rebuilt app copy.",
    receipt:
      '{"accessibility":false,"screenRecording":false,"microphone":false,"speechRecognition":false,"inputMonitoring":false}',
  },
  {
    title: "Scheduled wake for morning briefing",
    status: "not-working",
    tool: "automation wake scheduler",
    model: "gpt-oss:latest",
    prompt:
      "Every weekday at 7:25 AM, give me a concise spoken morning rundown of my mail, agenda, weather, portfolio and why markets moved.",
    latency: "Not scheduled",
    outcome: "Not eligible for a truthful pass: true wake requires the root LaunchDaemon helper and an actual scheduled sleep/wake observation. “Test now” is insufficient.",
    receipt:
      '{"state":"blocked","reason":"Requires one-time administrator authorization to install the durable power-scheduler helper."}',
  },
  {
    title: "Model planner regression",
    status: "planning",
    tool: "tool selection",
    model: "gpt-oss:latest",
    prompt: "Put on a short lo-fi coding mix and make it fill the screen.",
    latency: "3.88 s",
    outcome: "The raw planner chose fullscreen only, omitting playback. The deterministic natural-language route now handles this phrasing.",
    receipt: '{"selected":["youtube_fullscreen"],"status":"planning regression found"}',
  },
];

const categories = [
  ["GitHub", 23], ["Gmail", 20], ["Calendar", 15], ["Ungrouped", 15],
  ["Slack", 14], ["Notion", 12], ["Git", 10], ["Finder", 10],
  ["Browser", 9], ["Terminal", 8], ["Messages", 7], ["System", 7],
  ["Xcode", 7], ["VS Code", 7], ["Photos", 7], ["Obsidian", 7],
  ["Spotify", 6], ["Chrome", 6], ["Codex", 6], ["Contacts", 6],
  ["Preview", 4], ["Google", 4],
  ["Applications", 2], ["Weather", 1], ["Automation", 1],
];

const statusLabel: Record<Status, string> = {
  verified: "Verified",
  planning: "Planning only",
  unreliable: "Not reliable yet",
  blocked: "Blocked by permission / sign-in",
  "not-working": "Not working",
};

export default function Home() {
  return (
    <main>
      <section className="hero">
        <div className="grid-glow" aria-hidden="true" />
        <p className="eyebrow">NEXUS / EXPERIMENTAL BRANCH</p>
        <h1>Tools, receipts,<br /><span>no hand-waving.</span></h1>
        <p className="lede">
          A live validation board for the 214-tool Nexus registry. Every card
          names the natural-language prompt, model, real receipt, latency, and
          the reason it is—or is not—ready for automation.
        </p>
        <div className="metric-row" aria-label="Validation summary">
          <div><b>214</b><span>registered tools</span></div>
          <div><b>24</b><span>categories</span></div>
          <div><b>gpt-oss:latest</b><span>installed test model</span></div>
          <div><b>Experimental</b><span>branch under test</span></div>
        </div>
      </section>

      <section className="callout">
        <div className="pulse" aria-hidden="true" />
        <div>
          <p className="eyebrow">CURRENT TRUTH</p>
          <h2>Headless routing and real YouTube playback are exercised; durable macOS permissions, account sign-in, and true scheduled wake are not proven.</h2>
        </div>
      </section>

      <section className="section-heading">
        <div>
          <p className="eyebrow">STATUS FROM CRITICAL TO CONFIRMED</p>
          <h2>Observed workflows</h2>
        </div>
        <p>Green is reserved for a proven result. A plan, a dry run, or a friendly error never counts as a pass.</p>
      </section>

      <section className="evidence-grid">
        {evidence.map((item) => (
          <article className={`evidence-card status-${item.status}`} key={item.title}>
            <header>
              <span className="status-pill">{statusLabel[item.status]}</span>
              <span className="latency">{item.latency}</span>
            </header>
            <h3>{item.title}</h3>
            <dl>
              <div><dt>Tested capability</dt><dd>{item.tool}</dd></div>
              <div><dt>Model</dt><dd>{item.model}</dd></div>
              <div className="wide"><dt>Natural prompt</dt><dd>“{item.prompt}”</dd></div>
              <div className="wide"><dt>Observed output</dt><dd>{item.outcome}</dd></div>
            </dl>
            <pre>{item.receipt}</pre>
            {item.note ? <p className="note">{item.note}</p> : null}
          </article>
        ))}
      </section>

      <section className="inventory">
        <div className="inventory-copy">
          <p className="eyebrow">FULL SURFACE MAP</p>
          <h2>All tools are cataloged.<br />Execution claims are kept separate.</h2>
          <p>
            The count below is taken from the running Experimental build’s
            headless registry. Catalog presence does not imply live connector
            access, a signed-in browser profile, or macOS permission.
          </p>
        </div>
        <div className="category-grid">
          {categories.map(([name, count]) => (
            <div className="category" key={name as string}>
              <span>{name}</span><b>{count}</b>
            </div>
          ))}
        </div>
      </section>

      <section className="next-up">
        <p className="eyebrow">WHAT MUST HAPPEN BEFORE A REAL MORNING BRIEFING PASS</p>
        <ol>
          <li><span>01</span>Install a certificate-backed Nexus signing identity, then grant the specific macOS privacy permissions to that stable identity.</li>
          <li><span>02</span>Sign into Gmail, Calendar, Schoology, and read-only Fidelity inside the separate Nexus Chrome profile—never by copying personal browser secrets.</li>
          <li><span>03</span>Authorize the one-time power-scheduler helper, create an actual near-future wake, put the Mac to sleep, and observe the scheduled wake and spoken output.</li>
        </ol>
      </section>

      <footer>
        <span>Last refreshed from live Experimental receipts</span>
        <span>Model note: “GPT-OS 22” is not installed; all model claims here are for <b>gpt-oss:latest</b>.</span>
      </footer>
    </main>
  );
}
