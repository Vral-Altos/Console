"""Console E2E on emulators with a real Mac worker (README, "End-to-end test"):
sign-in gate, Overview live data, Projects, System, Logs, the link to Genie
(the chat lives there: apps/genie/e2e), phone layout."""
import re, sys
from playwright.sync_api import sync_playwright, expect

URL = 'http://localhost:5055/'
OUT = sys.argv[1]

def enable_semantics(page):
    page.wait_for_selector('flt-semantics-placeholder', state='attached', timeout=30000)
    page.evaluate("document.querySelector('flt-semantics-placeholder').click()")
    page.wait_for_timeout(500)

def sign_in(page, email):
    with page.expect_popup() as pop:
        page.get_by_role('button', name=re.compile('Sign in with Google')).click()
    p = pop.value
    p.wait_for_load_state()
    p.get_by_text('Add new account').click()
    p.locator('#email-input').fill(email)
    p.locator('#display-name-input').fill('Operator')
    p.locator('#sign-in').click()

def seen(page, pattern):
    """Text on screen. Flutter merges a card's texts into one accessible
    label, so this matches visible text or any element's aria-label."""
    rx = pattern if isinstance(pattern, re.Pattern) else re.compile(re.escape(pattern))
    return page.get_by_text(rx).or_(page.get_by_label(rx)).first

def tab(page, name):
    page.get_by_role('button', name=re.compile(f'^{name} Tab')).click()
    page.wait_for_timeout(700)

with sync_playwright() as pw:
    b = pw.chromium.launch()
    ctx = b.new_context(viewport={'width': 1440, 'height': 900})
    page = ctx.new_page()
    errors = []
    page.on('console', lambda m: errors.append(m.text) if m.type == 'error' else None)

    # 1. A stranger is refused.
    page.goto(URL); enable_semantics(page)
    sign_in(page, 'obsidian.infinitum@gmail.com')
    expect(seen(page, 'Not authorised')).to_be_visible(timeout=20000)
    page.get_by_role('button', name='Sign out').click()
    print('stranger refused: ok')

    # 2. The operator gets in; the Overview shows the live Mac worker.
    sign_in(page, 'siddharth.chitikela@gmail.com')
    expect(page.get_by_role('button', name=re.compile('^Overview Tab'))).to_be_visible(timeout=30000)
    page.add_style_tag(content='.firebase-emulator-warning{display:none!important}')
    expect(seen(page, 'Mac worker')).to_be_visible(timeout=20000)
    expect(seen(page, 'Serving')).to_be_visible(timeout=90000)
    expect(seen(page, 'Live now')).to_be_visible()
    page.screenshot(path=f'{OUT}/1-overview.png')
    print('overview: ok')

    # 3. Chat is Genie's: the sidebar links there (a new tab), with no Chat page.
    expect(page.get_by_role('button', name=re.compile('^Chat Tab'))).to_have_count(0)
    opened = []
    ctx.route('https://genie.vraltos.dev/**', lambda route: (opened.append(route.request.url), route.fulfill(body='Genie')))
    with ctx.expect_page() as genie:
        page.get_by_role('button', name='Open Genie').click()
    genie.value.wait_for_load_state()
    assert opened and opened[0].startswith('https://genie.vraltos.dev/'), opened
    genie.value.close()
    print('genie link: ok')

    # 4. Projects and System render live data.
    tab(page, 'Projects')
    expect(page.get_by_role('button', name='New Devstation')).to_be_visible()
    page.screenshot(path=f'{OUT}/2-projects.png')
    tab(page, 'System')
    expect(seen(page, 'Agent sessions')).to_be_visible()
    page.screenshot(path=f'{OUT}/3-system.png')
    print('projects and system: ok')

    # 5. Logs: the worker's entries, metrics and the activity trail.
    tab(page, 'Logs')
    expect(seen(page, re.compile('Worker started|Turn done with|Conversation filed')).first).to_be_visible(timeout=60000)
    page.get_by_role('tab', name=re.compile('Monitoring')).click()
    page.wait_for_timeout(1500)
    page.screenshot(path=f'{OUT}/4-monitoring.png')
    page.get_by_role('tab', name=re.compile('Activity')).click()
    page.wait_for_timeout(1500)
    page.screenshot(path=f'{OUT}/5-activity.png')
    print('logs, monitoring and activity: ok')

    # 6. A phone: the bottom bar and the Genie button.
    page.set_viewport_size({'width': 390, 'height': 844})
    page.wait_for_timeout(1500)
    page.get_by_role('tab', name=re.compile('Overview')).click()
    page.wait_for_timeout(1200)
    expect(page.get_by_role('button', name=re.compile('Open Genie'))).to_be_visible()
    page.screenshot(path=f'{OUT}/6-phone-overview.png')
    print('phone: ok')

    bad = [e for e in errors if 'favicon' not in e]
    print('console errors:', bad[:8])
    b.close()
