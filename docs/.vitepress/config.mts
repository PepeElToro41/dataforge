import { defineConfig } from "vitepress"

export default defineConfig({
	title: "DataForge",
	description: "Roblox DataStore library with cross-key transactions, session-locked and lockless profiles, migrations and an immutable data model.",
	cleanUrls: true,
	base: process.env.DOCS_BASE ?? "/",

	markdown: {
		languageAlias: { luau: "lua" },
	},

	themeConfig: {
		nav: [
			{ text: "Guide", link: "/guide/introduction", activeMatch: "/guide/" },
			{ text: "API Reference", link: "/api/dataforge", activeMatch: "/api/" },
		],

		// Sidebars are keyed by path: the guide never links into the API pages
		// and vice versa. The API section is only reachable from the top nav.
		sidebar: {
			"/guide/": [
				{
					text: "Guide",
					items: [
						{ text: "Introduction", link: "/guide/introduction" },
						{ text: "Getting Started", link: "/guide/getting-started" },
						{ text: "Profiles", link: "/guide/profiles" },
						{ text: "Lockless Profiles", link: "/guide/lockless-profiles" },
						{ text: "Transactions", link: "/guide/transactions" },
						{ text: "Migrations", link: "/guide/migrations" },
						{ text: "Testing", link: "/guide/testing" },
					],
				},
			],
			"/api/": [
				{
					text: "API Reference",
					items: [
						{ text: "dataforge", link: "/api/dataforge" },
						{ text: "Store", link: "/api/store" },
						{ text: "Profile", link: "/api/profile" },
						{ text: "LocklessProfile", link: "/api/lockless-profile" },
						{ text: "PeekProfile", link: "/api/peek-profile" },
						{ text: "Transactions", link: "/api/transactions" },
						{ text: "Errors", link: "/api/errors" },
						{ text: "Hooks & Schedulers", link: "/api/hooks" },
						{ text: "Types", link: "/api/types" },
					],
				},
			],
		},

		search: { provider: "local" },
		outline: [2, 3],
	},
})
