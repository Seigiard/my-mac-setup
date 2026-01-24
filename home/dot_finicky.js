// @ts-check

/**
 * @typedef {import('/Applications/Finicky.app/Contents/Resources/finicky.d.ts').FinickyConfig} FinickyConfig
 */

/**
 * @type {FinickyConfig}
 */
export default {
  defaultBrowser: "Brave Browser",
  rewrite: [
    {
      match: ["*.slack.com/*"],
      url: function (url) {
        const subdomain = url.host.slice(0, -10);
        const pathParts = url.pathname.split("/");

        let team,
          patterns = {};
        if (subdomain != "app") {
          switch (subdomain) {
            case "getmembrane":
              team = "T028H30HP63";
              break;
            default:
              console.warn(
                `No Slack team ID found for ${url.host}`,
                `Add the team ID to ~/.finicky.js to allow direct linking to Slack.`,
              );
              return url;
          }

          patterns = {
            file: [/\/messages\/\w+\/files\/(?<id>\w+)/],
            team: [/(?:\/messages\/\w+)?\/team\/(?<id>\w+)/],
            channel: [/\/(?:messages|archives)\/(?<id>\w+)(?:\/(?<message>p\d+))?/],
          };
        } else {
          patterns = {
            file: [/\/client\/(?<team>\w+)\/\w+\/files\/(?<id>\w+)/, /\/docs\/(?<team>\w+)\/(?<id>\w+)/],
            team: [/\/client\/(?<team>\w+)\/\w+\/user_profile\/(?<id>\w+)/],
            channel: [/\/client\/(?<team>\w+)\/(?<id>\w+)(?:\/(?<message>[\d.]+))?/],
          };
        }

        for (let [host, host_patterns] of Object.entries(patterns)) {
          for (let pattern of host_patterns) {
            let match = pattern.exec(url.pathname);
            if (match) {
              let search = `team=${team || match.groups.team}`;

              if (match.groups.id) {
                search += `&id=${match.groups.id}`;
              }

              if (match.groups.message) {
                let message = match.groups.message;
                if (message.charAt(0) == "p") {
                  message = message.slice(1, 11) + "." + message.slice(11);
                }
                search += `&message=${message}`;
              }

              const newUrl = new URL(`slack://${host}`);
              newUrl.search = search;

              console.log(`Rewrote Slack URL ${url.toString()} to deep link ${newUrl.toString()}`);
              return newUrl;
            }
          }
        }

        return url;
      },
    },
  ],
  handlers: [
    {
      match: finicky.matchHostnames(["localhost", "console.integration.app"]),
      browser: "Brave Browser",
    },
    {
      match: "www.figma.com/file/*",
      browser: "Figma",
    },
    {
      match: "www.figma.com/design/*",
      browser: "Figma",
    },
    {
      match: "*.zoom.us/j/*",
      browser: "/Applications/zoom.us.app",
    },
    {
      match: "https://linear.app/integration-app/*",
      browser: "Linear",
    },
    {
      match: (url) => url.protocol === "slack:",
      browser: "/Applications/Slack.app",
    },
  ],
};
