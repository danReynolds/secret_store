const tabs = Array.from(document.querySelectorAll('[role="tab"]'));
const panels = Array.from(document.querySelectorAll('[role="tabpanel"]'));

function selectTab(selectedTab) {
  for (const tab of tabs) {
    const selected = tab === selectedTab;
    tab.setAttribute('aria-selected', String(selected));
    tab.tabIndex = selected ? 0 : -1;
  }

  for (const panel of panels) {
    panel.hidden = panel.id !== selectedTab.getAttribute('aria-controls');
  }
}

for (const [index, tab] of tabs.entries()) {
  tab.addEventListener('click', () => selectTab(tab));
  tab.addEventListener('keydown', (event) => {
    if (!['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) {
      return;
    }

    event.preventDefault();
    let nextIndex;
    if (event.key === 'Home') nextIndex = 0;
    if (event.key === 'End') nextIndex = tabs.length - 1;
    if (event.key === 'ArrowLeft') nextIndex = (index - 1 + tabs.length) % tabs.length;
    if (event.key === 'ArrowRight') nextIndex = (index + 1) % tabs.length;

    const nextTab = tabs[nextIndex];
    selectTab(nextTab);
    nextTab.focus();
  });
}

const copyStatus = document.querySelector('.copy-status');
let copyStatusTimer;

function showCopyStatus(message) {
  copyStatus.textContent = message;
  copyStatus.classList.add('is-visible');
  window.clearTimeout(copyStatusTimer);
  copyStatusTimer = window.setTimeout(() => {
    copyStatus.classList.remove('is-visible');
  }, 1600);
}

async function copyText(value) {
  if (navigator.clipboard?.writeText) {
    try {
      await navigator.clipboard.writeText(value);
      return;
    } catch {
      // The legacy path below also works in browsers that block the modern
      // clipboard API for a local or embedded preview.
    }
  }

  const input = document.createElement('textarea');
  input.value = value;
  input.setAttribute('readonly', '');
  input.style.position = 'fixed';
  input.style.opacity = '0';
  document.body.append(input);
  input.select();
  const copied = document.execCommand('copy');
  input.remove();
  if (!copied) throw new Error('clipboard unavailable');
}

for (const button of document.querySelectorAll('[data-copy-target]')) {
  button.addEventListener('click', async () => {
    const target = document.getElementById(button.dataset.copyTarget);
    const value = target?.innerText ?? '';

    try {
      await copyText(value);
      button.textContent = 'Copied';
      showCopyStatus('Copied to clipboard');
      window.setTimeout(() => {
        button.textContent = 'Copy';
      }, 1400);
    } catch {
      showCopyStatus('Copy unavailable; select the code manually');
    }
  });
}
