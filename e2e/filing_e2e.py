"""Chat filing E2E on emulators with a real worker (README, "End-to-end test";
same setup as console_e2e.py): a reply shows its model, tokens, cost and
quota; the conversation is named `[PROJECT] (COST) DD/MM: TOPIC`, filed under
a project by the namer, grouped by project and purpose, and refiled by hand.
    python3 e2e/filing_e2e.py <screenshot dir>
Start from an empty Firestore emulator (one conversation)."""
import re, sys
from playwright.sync_api import sync_playwright, expect

# Helpers as in console_e2e.py.
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
    return page.get_by_text(rx).or_(page.get_by_label(rx)).or_(page.get_by_role('group', name=rx)).first

def tab(page, name):
    page.get_by_role('button', name=re.compile(f'^{name} Tab')).click()
    page.wait_for_timeout(700)

def type_and_send(page, box_name, text):
    box = page.get_by_role('textbox', name=box_name)
    box.click()
    page.wait_for_timeout(400)
    page.keyboard.type(text)
    expect(box).to_have_value(text)
    page.keyboard.press('Enter')  # Enter sends

def click_any(page, *patterns):
    """Clicks the first visible element whose text, label or role name
    matches one of [patterns]; on failure lists what is there."""
    for rx in patterns:
        for loc in [page.get_by_role('button', name=rx), page.get_by_role('radio', name=rx),
                    page.get_by_role('menuitem', name=rx), page.get_by_text(rx), page.get_by_label(rx)]:
            for el in loc.all():
                if el.is_visible():
                    el.click()
                    page.wait_for_timeout(400)
                    return
    names = page.locator('flt-semantics').evaluate_all(
        "els => els.map(e => e.getAttribute('aria-label') || e.getAttribute('role') + ':' + (e.innerText || '').slice(0, 40)).filter(Boolean)")
    raise AssertionError(f'none of {patterns} on screen; semantics: {names[:80]}')


URL = 'http://localhost:5055/'
OUT = sys.argv[1]
NAME = re.compile(r'^\[([^\]]+)\] \(<?\$[\d.]+\) \d\d\/\d\d: .+')

with sync_playwright() as pw:
    b = pw.chromium.launch()
    page = b.new_context(viewport={'width': 1440, 'height': 900}).new_page()
    errors = []
    page.on('console', lambda m: errors.append(m.text) if m.type == 'error' else None)
    page.goto(URL); enable_semantics(page)
    sign_in(page, 'siddharth.chitikela@gmail.com')
    expect(page.get_by_role('button', name=re.compile('^Overview Tab'))).to_be_visible(timeout=30000)
    page.add_style_tag(content='.firebase-emulator-warning{display:none!important}')
    expect(seen(page, 'Serving')).to_be_visible(timeout=90000)
    tab(page, 'Chat')

    # The operator keeps the projects: add two.
    page.get_by_role('button', name='Projects', exact=True).click()
    for name in ['Financier', 'EOS']:
        box = page.get_by_role('textbox', name='New project')
        box.click()
        page.wait_for_timeout(300)
        page.keyboard.press('Meta+a'); page.keyboard.press('Backspace')
        page.keyboard.type(name)
        expect(box).to_have_value(name)
        page.get_by_role('button', name='Add', exact=True).click()
        expect(seen(page, name)).to_be_visible(timeout=10000)
    page.screenshot(path=f'{OUT}/filing-1-projects.png')
    page.get_by_role('button', name='Done').click()
    print('projects added: ok')

    # A new chat, project Auto: the namer files it after the first reply.
    type_and_send(page, 'Message Genie…', 'In one short sentence: what does the Financier tool track?')
    reply_usage = seen(page, re.compile(r'context · .* out · <?\$[\d.]+ · 5h \d+%'))
    expect(reply_usage).to_be_visible(timeout=240000)
    print('reply usage:', re.search(r'\S+ \d\.\d · [^\n]*7d \d+%', (reply_usage.get_attribute('aria-label') or '') + (reply_usage.text_content() or '')).group(0))
    header = seen(page, re.compile(r'^\[Financier\] \(<?\$[\d.]+\) \d\d\/\d\d: '))
    expect(header).to_be_visible(timeout=120000)
    print('named:', header.get_attribute('aria-label') or header.text_content())
    page.wait_for_timeout(1500)
    page.screenshot(path=f'{OUT}/filing-2-conversation.png')
    # Header chips (model, 5h / 7d meters, cost) are tooltips to the
    # accessibility tree; filing-2-conversation.png shows them.

    # Grouped by project, then by purpose.
    expect(seen(page, re.compile(r'Financier\s+1 · <?\$'))).to_be_visible()
    click_any(page, re.compile(r'^Purpose'), re.compile('Group by purpose'))
    page.wait_for_timeout(500)
    page.screenshot(path=f'{OUT}/filing-3-by-purpose.png')
    click_any(page, re.compile(r'^Project(?!s)'), re.compile('Group by project'))

    # Refiled by hand: Move to project → EOS; the name follows.
    try:
        page.get_by_role('button', name=re.compile('Conversation options')).first.click(timeout=8000)
    except Exception:
        print('buttons:', [x.get_attribute('aria-label') or x.text_content() for x in page.get_by_role('button').all()][:60])
        raise
    page.wait_for_timeout(500)
    click_any(page, re.compile('Move to project'))
    page.wait_for_timeout(500)
    click_any(page, re.compile(r'^EOS$'), re.compile(r'^EOS'))
    expect(seen(page, re.compile(r'^\[EOS\] \(<?\$'))).to_be_visible(timeout=10000)
    page.screenshot(path=f'{OUT}/filing-4-refiled.png')
    print('refiled: ok')

    # Phone width.
    page.set_viewport_size({'width': 390, 'height': 844})
    page.wait_for_timeout(800)
    page.screenshot(path=f'{OUT}/filing-5-phone.png')
    bad = [e for e in errors if 'emulator' not in e.lower()]
    print('console errors:', bad[:5])
    b.close()
