import dataforge = require("../..");

interface PreviousData {
	coins: number;
}

interface PlayerData extends PreviousData {
	gems: number;
}

declare function isPreviousData(value: unknown): value is PreviousData;

const addCoins: dataforge.Migration<PreviousData> = {
	name: "add_coins",
	apply: () => ({ coins: 0 }),
};

const addGems: dataforge.Migration<PlayerData> = {
	name: "add_gems",
	apply: (data) => {
		// @ts-expect-error Stored migration input must be narrowed before use.
		data.coins;
		if (!isPreviousData(data)) {
			error("Invalid previous data");
		}
		return { coins: data.coins, gems: 0 };
	},
};

dataforge.create_store<PlayerData>({
	name: "NoMigrations",
	template: { coins: 0, gems: 0 },
});

dataforge.create_store<PlayerData>({
	name: "EmptyHistory",
	template: { coins: 0, gems: 0 },
	migrations: [],
});

const migrations: dataforge.Migrations<PlayerData> = [addCoins, addGems];
const store = dataforge.create_store<PlayerData>({
	name: "TypedHistory",
	template: { coins: 0, gems: 0 },
	migrations,
});
const loaded: dataforge.Result<dataforge.Profile<PlayerData>> = store.load("key", []);

const config: dataforge.Config<PlayerData> = {
	name: "InvalidHistory",
	template: { coins: 0, gems: 0 },
	// @ts-expect-error The final migration must include PlayerData.gems.
	migrations: [addCoins],
};

const badStep: dataforge.Migration<PlayerData> = {
	name: "missing_gems",
	// @ts-expect-error Explicit intermediate targets check the callback output.
	apply: () => ({ coins: 0 }),
};

dataforge.create_store<PlayerData>({
	name: "InvalidInlineOutput",
	template: { coins: 0, gems: 0 },
	// @ts-expect-error An unrelated return value cannot become PlayerData.
	migrations: [{ name: "broken", apply: () => "wrong" }],
});

const inferred = dataforge.create_store({
	name: "InferredSchema",
	template: { coins: 0, gems: 0 },
	migrations: [addCoins, addGems],
});
const inferredStore: dataforge.Store<PlayerData> = inferred;

dataforge.create_store({
	name: "InvalidInferredOutput",
	template: { coins: 0, gems: 0 },
	// @ts-expect-error Template inference must still check the final output.
	migrations: [{ name: "broken", apply: () => ({ coins: 0 }) }],
});

// Unparameterized migration entries remain available for intermediate outputs.
const untypedStep: dataforge.Migration = { name: "legacy", apply: () => 1 };

const wrongField: dataforge.Migration<PlayerData> = {
	name: "wrong_field_type",
	// @ts-expect-error The final schema requires a numeric gems field.
	apply: () => ({ coins: 0, gems: "wrong" }),
};

// No callback annotations, migration generics, or history annotations needed.
const inlineStore = dataforge.create_store({
	name: "InlineInferredHistory",
	template: { coins: 0, gems: 0 },
	migrations: [
		{ name: "add_coins", apply: () => ({ coins: 0 }) },
		{ name: "add_gems", apply: () => ({ coins: 0, gems: 0 }) },
	],
});
const checkedInlineStore: dataforge.Store<PlayerData> = inlineStore;

dataforge.create_store({
	name: "InlineWrongFinalField",
	template: { coins: 0, gems: 0 },
	// @ts-expect-error No annotation is needed to reject a wrong final field type.
	migrations: [{ name: "broken", apply: () => ({ coins: 0, gems: "wrong" }) }],
});

dataforge.create_store({
	name: "InlineMissingFinalField",
	template: { coins: 0, gems: 0 },
	// @ts-expect-error The final step is checked even after intermediate steps.
	migrations: [
		{ name: "add_coins", apply: () => ({ coins: 0 }) },
		{ name: "broken", apply: () => ({ coins: 0 }) },
	],
});

// This intentionally compiles: only the final step has an automatic target.
dataforge.create_store({
	name: "IntermediateStepHasNoAutomaticTarget",
	template: { coins: 0, gems: 0 },
	migrations: [
		{ name: "broken_intermediate", apply: () => "wrong" },
		{ name: "final", apply: () => ({ coins: 0, gems: 0 }) },
	],
});
