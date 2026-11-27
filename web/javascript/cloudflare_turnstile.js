(() => {
  const TURNSTILE_SCRIPT_SRC =
    'https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit';

  let scriptPromise = null;
  const widgetIds = new Map();

  function loadTurnstileScript() {
    if (window.turnstile && typeof window.turnstile.render === 'function') {
      return Promise.resolve(window.turnstile);
    }

    if (scriptPromise) {
      return scriptPromise;
    }

    scriptPromise = new Promise((resolve, reject) => {
      const existing = document.querySelector(
        `script[src="${TURNSTILE_SCRIPT_SRC}"]`
      );
      if (existing) {
        existing.addEventListener('load', () => resolve(window.turnstile), {
          once: true,
        });
        existing.addEventListener(
          'error',
          () => reject(new Error('Failed to load Cloudflare Turnstile script.')),
          { once: true }
        );
        return;
      }

      const script = document.createElement('script');
      script.src = TURNSTILE_SCRIPT_SRC;
      script.async = true;
      script.defer = true;
      script.onload = () => {
        if (window.turnstile) {
          resolve(window.turnstile);
        } else {
          reject(new Error('Turnstile API unavailable after script load.'));
        }
      };
      script.onerror = () => {
        scriptPromise = null;
        reject(new Error('Failed to load Cloudflare Turnstile script.'));
      };
      document.head.appendChild(script);
    });

    return scriptPromise;
  }

  function removeWidget(containerId) {
    const widgetId = widgetIds.get(containerId);
    if (widgetId !== undefined && window.turnstile) {
      try {
        window.turnstile.remove(widgetId);
      } catch (_) {
        // Ignore cleanup errors if container was already removed.
      }
    }
    widgetIds.delete(containerId);
  }

  window.cloudflareTurnstileBridge = {
    async verify(containerId, siteKey, theme = 'auto') {
      if (!siteKey) {
        throw new Error('Missing Cloudflare Turnstile site key.');
      }

      const container = document.getElementById(containerId);
      if (!container) {
        throw new Error(`Turnstile container "#${containerId}" not found.`);
      }

      removeWidget(containerId);
      container.innerHTML = '';

      const turnstile = await loadTurnstileScript();

      return await new Promise((resolve, reject) => {
        let settled = false;

        const finishResolve = (token) => {
          if (settled) return;
          settled = true;
          resolve(token);
        };

        const finishReject = (err) => {
          if (settled) return;
          settled = true;
          reject(err instanceof Error ? err : new Error(String(err)));
        };

        const widgetId = turnstile.render(container, {
          sitekey: siteKey,
          theme: theme,
          callback: (token) => {
            if (!token) {
              finishReject(new Error('Empty Turnstile token returned.'));
              return;
            }
            finishResolve(token);
          },
          'error-callback': (code) => {
            finishReject(
              new Error(
                code ? `Turnstile error (${code}).` : 'Turnstile verification failed.'
              )
            );
          },
          'expired-callback': () => {
            finishReject(new Error('Turnstile challenge expired. Please try again.'));
          },
        });

        widgetIds.set(containerId, widgetId);
      });
    },

    reset(containerId) {
      const widgetId = widgetIds.get(containerId);
      if (widgetId !== undefined && window.turnstile) {
        try {
          window.turnstile.reset(widgetId);
        } catch (_) {
          // Ignore reset errors.
        }
      }
    },

    cleanup(containerId) {
      removeWidget(containerId);
    },
  };
})();