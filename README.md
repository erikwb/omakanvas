# Omakanvas

Omakanvas is a community fork of
[Omacanvas](https://github.com/christopherhaynes33/omacanvas) by Christopher
Haynes (MIT licensed, copyright retained in [LICENSE](LICENSE)), continuing
with browser-session login, per-course announcements, discussions, messages,
and panel sign-in.

Migrating from Omacanvas? Remove the old widget, add Omakanvas, and set the
same `baseUrl`. Saved browser sessions, tokens, and hidden-course preferences
carry over automatically.

Recent changes were hella vibed by Muse Spark 1.3.

Omakanvas is a native Omarchy Quickshell bar widget for Canvas LMS. It shows
current grades and assignments due soon for students, plus upcoming assignment
deadlines and grading counts for teachers. Accounts with both roles can switch
between Student and Teaching views.

Omakanvas is an independent community project and is not affiliated with,
endorsed by, or sponsored by Instructure or Canvas LMS.

![Omakanvas Student Assignments, Teaching Overview, and Teaching Courses views](preview.png?v=1.0.0)

The panel provides three views:

- **Overview** — assignment and course summaries, plus grades or grading counts.
- **Assignments** — student work or teaching deadlines during the configured window.
- **Courses** — per-course details, assignments, recent announcements, discussions, unread messages, links, and visibility controls.

## Requirements

- A current Omarchy installation using the standard Quickshell bar.
- Python 3.10 or newer.
- `secret-tool`, provided by the `libsecret` package, for secure credential storage.
- A Chromium-family browser (Chromium, Chrome, Brave, Edge, or Vivaldi) for
  browser login, or a Canvas account permitted to create personal access tokens.

Install the keyring tool if it is not already available:

```sh
omarchy pkg add libsecret
```

## Install

Install directly from the public GitHub repository and enable the widget:

```sh
omarchy plugin add https://github.com/erikwb/omakanvas.git --enable
```

Choose a bar section when prompted. The default section is the right side.

## Configure Canvas

Omakanvas needs the HTTPS base URL of the Canvas installation and either a
browser session or a personal access token. The URL is stored in Omarchy's
normal widget settings. Credentials are stored in the system keyring and
scoped to that configured URL, so separate Canvas installations can use
separate logins. A browser-login record also contains the validated API origin
in case Canvas redirects the configured address to a different canonical host.

### 1. Find the Canvas base URL

Open Canvas in a browser and copy only the origin from the address bar. Do not
include a course or assignment path. Omakanvas accepts HTTPS URLs only.

For example, if a course URL is:

```text
https://canvas.example.edu/courses/12345
```

the base URL is:

```text
https://canvas.example.edu
```

Set it with Omarchy's bar command:

```sh
omarchy bar set io.github.erikwb.omakanvas baseUrl https://canvas.example.edu
```

### 2. Sign in through the browser

Run the installed helper; it reads the URL from the Omarchy bar setting:

```sh
~/.config/omarchy/plugins/io.github.erikwb.omakanvas/omacanvas login
```

An explicit `--base-url` takes precedence when needed.

Omakanvas opens an isolated browser window. Complete the institution's normal
Canvas login, including SSO or MFA. Omakanvas follows the HTTPS origins reached
by the isolated login window and accepts a `canvas_session` cookie only after
that origin successfully answers Canvas's `/api/v1/users/self` endpoint. It
stores the validated API base URL alongside the cookie in the desktop keyring,
then closes the isolated window. It does not read cookies from the normal
browser profile or retain the temporary profile.

The browser session is used for read-only API requests and takes precedence if
a personal token is also saved. Session lifetime is controlled by Canvas and
the institution; run `login` again if Canvas expires it. This login method uses
Canvas's web session rather than its documented OAuth flow, so an institution
or future Canvas release may disable it. Personal access tokens remain
available as a fallback.

If automatic browser detection does not find the desired browser, pass its
executable explicitly:

```sh
~/.config/omarchy/plugins/io.github.erikwb.omakanvas/omacanvas login \
  --browser /usr/bin/chromium
```

Right-click the Omakanvas bar icon after login to refresh immediately.

### 3. Optional: create a Canvas API token

> [!IMPORTANT]
> Instructure documents manual token generation as a testing workflow and
> requires OAuth for applications used by multiple users. Omakanvas does not
> implement OAuth. Before using its optional token fallback, confirm that your
> institution permits a manually generated token for a local, personal client.
> See the [Canvas OAuth2 documentation](https://developerdocs.instructure.com/services/canvas/oauth2/file.oauth).

If browser login is unavailable or unreliable for the institution, create a
personal token in Canvas:

1. Open **Account → Settings**.
2. Find **Approved Integrations**.
3. Select **New Access Token**.
4. Enter a purpose such as `Omakanvas` and, if desired, an expiration date.
5. Select **Generate Token**.
6. Copy the token immediately. Canvas normally displays the complete token
   only once.

Some institutions disable personal access tokens. If **New Access Token** is
not available, contact the institution's Canvas administrator.

Treat the token like a password.

### 4. Save the optional token in the keyring

Run the installed helper and enter the token at the hidden prompt:

```sh
~/.config/omarchy/plugins/io.github.erikwb.omakanvas/omacanvas set-token
```

The URL must match the configured base URL after trailing slashes are removed.
Setting a token again replaces the saved token for that Canvas installation.

If a browser session is also saved, it remains preferred. Run `clear-session`
to switch back to the token.

## Use the widget

- Left-click the bar icon to open or close the panel.
- Right-click the bar icon to refresh Canvas data manually.
- When both roles are available, select the **STUDENT** or **TEACHING** label
  at the right side of the header to toggle roles.
- Select **Overview**, **Assignments**, or **Courses** at the top of the panel.
- Select an assignment name to open it in Canvas.
- Select a course name to open its Canvas landing page.
- Press `1`, `2`, or `3` to select a view while the panel is focused.
- Press `S` or `T` to select Student or Teaching while the panel is focused.
- Press Left/Right to change views and Up/Down to scroll.
- Press `R` or Enter to refresh, and Escape to close the panel.
- Press `L` or select **Sign in with Canvas** when it appears to sign in
  from the panel instead of the terminal; signing in opens a browser window
  and continues automatically once login completes.

The widget refreshes every six hours by default and shows assignments due in
the next 14 days.

### Assignment status and availability

Student assignments use one compact status icon:

- No icon means the assignment is open and not submitted.
- A checkmark means Canvas reports the assignment as submitted.
- A lock means Canvas reports the assignment as locked for the current user.

On the student **Assignments** and **Courses** views, submitted assignments are
grouped under a collapsed disclosure below the open assignments. Select the
disclosure to review them; its expanded or collapsed state is shared between
the two views until the panel is closed. Teaching assignments are not grouped
this way. The Overview's **Next** line also skips submitted student work.

Locked student assignments show their future unlock date when Canvas provides
one. If Canvas reports the assignment as locked without a future unlock date,
Omakanvas displays **Locked · No scheduled unlock date**. Lock and submission
states are informational; selecting the assignment still opens its Canvas URL
when one is available.

### Teaching view

Teaching displays active courses in which Canvas reports a teacher enrollment.
It shows upcoming assignment deadlines, Published or Draft assignment status,
course Published or Unpublished status, and the course's total number of
submissions needing grading. A lock marks an assignment with a future scheduled
unlock. Assignments with differentiated dates show the number of availability
schedules and, when applicable, the earliest upcoming unlock. The teacher view
is read-only and does not retrieve individual submissions.

### Hide or restore a course

In **Courses**, use the eye-slash action to hide the selected course. Hidden
courses are excluded from assignment counts, alerts, and assignment,
announcement, discussion, and conversation API requests in both roles. Expand the muted hidden-course row and use the eye
action to restore a course.

Course visibility is stored per Canvas installation in:

```text
${XDG_CONFIG_HOME:-~/.config}/omacanvas/hidden-courses.json
```

## Settings

Settings are managed through `omarchy bar set`:

```sh
# Change the assignment window to 21 days.
omarchy bar set io.github.erikwb.omakanvas days 21 --json

# Change automatic refresh to every three hours.
omarchy bar set io.github.erikwb.omakanvas refreshIntervalSec 10800 --json

# Change Canvas installations. Sign in or save a token for the new URL separately.
omarchy bar set io.github.erikwb.omakanvas baseUrl https://other.example.edu
```

The assignment window accepts 1–60 days. The refresh interval accepts
300–86400 seconds.

## Manage credentials

Open an isolated browser and save its validated Canvas session:

```sh
~/.config/omarchy/plugins/io.github.erikwb.omakanvas/omacanvas login
```

Remove the locally saved browser session:

```sh
~/.config/omarchy/plugins/io.github.erikwb.omakanvas/omacanvas clear-session
```

This removes Omakanvas's keyring copy; it does not sign other browsers out of
Canvas.

Replace or add a token:

```sh
~/.config/omarchy/plugins/io.github.erikwb.omakanvas/omacanvas set-token
```

Remove the token for one Canvas installation:

```sh
~/.config/omarchy/plugins/io.github.erikwb.omakanvas/omacanvas clear-token
```

For temporary terminal use, explicitly select `CANVAS_API_KEY` instead of the
keyring. It is not written to disk and never overrides URL-scoped credentials
unless `--token-from-env` is present:

```sh
CANVAS_API_KEY='your-token' \
  ~/.config/omarchy/plugins/io.github.erikwb.omakanvas/omacanvas fetch \
  --token-from-env --base-url https://canvas.example.edu
```

Avoid placing a real token in shell history. Prefer the interactive
`set-token` command for normal use.

## Terminal commands

The helper can also be run independently:

```sh
OMACANVAS=~/.config/omarchy/plugins/io.github.erikwb.omakanvas/omacanvas

$OMACANVAS fetch
$OMACANVAS fetch --json
$OMACANVAS login
$OMACANVAS clear-session
$OMACANVAS set-token
$OMACANVAS clear-token
$OMACANVAS hide-course COURSE_ID --base-url https://canvas.example.edu \
  --course-name 'Orientation' --course-code 'ORIENT'
$OMACANVAS unhide-course COURSE_ID --base-url https://canvas.example.edu
```

Human-readable `fetch` output is divided into Student and Teaching sections.
With `--json`, both role payloads are returned under `roles`. The hide and
unhide commands are normally easier to use from the Courses view.

## Update, disable, or remove

Update the Git-managed plugin:

```sh
omarchy plugin update io.github.erikwb.omakanvas
```

Disable or re-enable the widget:

```sh
omarchy plugin disable io.github.erikwb.omakanvas
omarchy plugin enable io.github.erikwb.omakanvas --section right
```

Remove the plugin:

```sh
omarchy plugin remove io.github.erikwb.omakanvas
```

Removing the plugin does not remove browser sessions, tokens, or hidden-course
preferences. Use `clear-session` and `clear-token` before removal and delete
the Omakanvas configuration directory manually if those should also be removed.

## Privacy and permissions

Omakanvas sends authenticated HTTPS requests only to the configured Canvas
installation. It requests active student and teacher enrollments, student
scores/grades and submission status, teacher grading counts, course publication
status, and assignments due within the selected window. Assignment data
includes publication status and Canvas availability dates needed to display
lock and unlock information. Omakanvas also fetches every announcement,
discussion, and conversation for each visible course (titles/subjects, dates,
authors or participants, excerpts, and links) for the per-course screen; the
panel itself shows the three most recent announcements, the three most active
discussions, and up to three unread conversations
per course. The complete lists are included in `fetch --json` output so
external tools can process them. Teacher data is read-only; Omakanvas does not
retrieve individual submissions or change grades. Hidden courses skip
assignment, announcement, discussion, and conversation requests. The selected credential is read from the desktop keyring
and is never written to Omarchy's plain-text configuration. Browser login uses
a new private temporary browser profile and asks Chromium only for cookies
applicable to HTTPS origins reached during login. Only a validated
`canvas_session` value and its Canvas API base URL are retained. Assignment,
announcement, discussion, message, and course links are opened in the default browser only after Omakanvas verifies
that they use the validated Canvas origin; credentials are not included in
browser links.

Like every Omarchy shell plugin, Omakanvas runs as user code inside the shell.
Review third-party plugin source before installation.

## Troubleshooting

- **“Set your Canvas URL”** — configure `baseUrl` with the `omarchy bar set`
  command above.
- **“No Canvas credential is saved”** — select **Sign in with Canvas** in the
  panel, or run `login` or `set-token` with the
  exact same base URL configured for the widget.
- **Canvas rejected the browser session** — Canvas expired or revoked the web
  session; sign in again from the panel or run `login` again.
- **The browser closes before login completes** — rerun `login`, optionally
  with `--browser /path/to/chromium`, and keep the isolated window open through
  the Canvas dashboard redirect.
- **`secret-tool` is missing** — install `libsecret` with
  `omarchy pkg add libsecret`.
- **Canvas rejected the API token** — create a new token in Canvas and run
  `set-token` again.
- **The API-token option is missing in Canvas** — the institution may prohibit
  personal tokens; ask its Canvas administrator.
- **A course is missing** — Omakanvas displays active student and teacher
  enrollments. Check the selected role and hidden-courses disclosure.
- **The Student/Teaching toggle is missing** — the role label appears only when
  Canvas returns both active student and teacher roles. Accounts with one role
  open directly in that view.
- **A lock or unlock date looks stale** — right-click the bar icon to refresh;
  automatic refresh occurs every six hours by default.
- **Changes do not appear** — right-click the icon, then run
  `omarchy restart shell` if needed.

## Local development

From a checkout of this repository:

```sh
omarchy plugin validate .
python3 -m unittest discover -s tests
omarchy plugin add "$(pwd)" --enable
```

The helper uses only Python's standard library. Browser login communicates
with a locally launched Chromium-family browser through a process-private
DevTools pipe; no listening port, browser automation package, or extension is
required.

## License

Omakanvas is released under the MIT License. See [LICENSE](LICENSE).
