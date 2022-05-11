-- Based on component by sleitnick

type Composition = { string: table }

type AncestorList = { Instance }

type ExtensionShouldFn = (any) -> boolean

type Extension = {
	ShouldConstruct: ExtensionShouldFn?,
}

type Extensions = { { Extension }? }

type CompositionConfig = { Tag: string, Composition: Composition, Ancestors: AncestorList, Extensions: Extensions }

local CollectionService = game:GetService("CollectionService")

local DEFAULT_ANCESTORS = { workspace, game:GetService("Players") }

local Trove = require(script.Parent.Trove)
local Symbol = require(script.Parent.Symbol)
local Signal = require(script.Parent.Signal)
local TableUtil = require(script.Parent.TableUtil)
local Promise = require(script.Parent.Promise)

local KEY_ANCESTORS = Symbol("Ancestors")
local KEY_EXTENSIONS = Symbol("Extensions")
local KEY_TROVE = Symbol("Trove")
local KEY_COMPOSITION = Symbol("Composition")

local KEY_COMPOSITIONS = Symbol("Compositions")

local KEY_COMPOSERS = Symbol("Composers")

local KEY_CONSTRUCTED = Symbol("Constructed")
local KEY_STARTED = Symbol("Started")

local KEY_ANCESTOR = Symbol("Ancestor")

local function ShouldConstruct(self): boolean
	for _, extension in ipairs(self[KEY_EXTENSIONS]) do
		local fn = extension.ShouldConstruct
		if type(fn) == "function" then
			local shouldConstruct = fn(self)
			if not shouldConstruct then
				return false
			end
		end
	end
	return true
end

local Composition = {}
Composition.__index = Composition

Composition.Composer = require(script.Composer)

function Composition.new(config: CompositionConfig)
	local customComposition = {}
	customComposition.__index = customComposition

	customComposition[KEY_TROVE] = Trove.new()

	customComposition.Tag = config.Tag

	customComposition[KEY_COMPOSITION] = config.Composition or {}
	customComposition[KEY_ANCESTORS] = config.Ancestors or DEFAULT_ANCESTORS
	customComposition[KEY_EXTENSIONS] = config.Extensions or {}

	customComposition[KEY_COMPOSITIONS] = {}

	customComposition.Constructed = customComposition[KEY_TROVE]:Construct(Signal)

	setmetatable(customComposition, Composition)

	customComposition:_setup()

	return customComposition
end

function Composition:_setup()
	local watchingInstances = {}
	local instanceCompositions = {}

	local function TryConstructInstance(instance: Instance)
		if instanceCompositions[instance] then
			return
		end

		local composition = self:_instansiate(instance)

		if not ShouldConstruct(composition) then
			return
		end

		composition:_construct()
		composition:_start()

		--instanceCompositions[instance] = instanceCompositions[instance] or {}
		--table.insert(instanceCompositions[instance], composition)
		instanceCompositions[instance] = composition
	end

	local function TryDeconstructInstance(instance: Instance)
		local composition = instanceCompositions[instance]

		if not composition then
			return
		end

		--for _, composition in ipairs(compositions) do
		--composition:_stop()
		--end
		if composition[KEY_ANCESTOR] == instance.Parent then
			return
		end

		composition:_stop()
		instanceCompositions[instance] = nil
	end

	local function InstanceTagged(instance: Instance)
		local function IsInAncestorList(): boolean
			for _, parent in ipairs(self[KEY_ANCESTORS]) do
				if instance:IsDescendantOf(parent) then
					return true
				end
			end
			return false
		end

		watchingInstances[instance] = instance.AncestryChanged:Connect(function(_, parent)
			TryDeconstructInstance(instance)

			if parent and IsInAncestorList() then
				TryConstructInstance(instance)
			end
		end)

		if IsInAncestorList() then
			TryConstructInstance(instance)
		end
	end

	local function InstanceUntagged(instance: Instance)
		local composition = instanceCompositions[instance]
		if composition then
			composition:_stop()
			instanceCompositions[instance] = nil
		end

		local watchHandle = watchingInstances[instance]
		if watchHandle then
			watchHandle:Disconnect()
			watchingInstances[instance] = nil
		end
	end

	task.defer(function()
		self[KEY_TROVE]:Connect(CollectionService:GetInstanceAddedSignal(self.Tag), InstanceTagged)
		self[KEY_TROVE]:Connect(CollectionService:GetInstanceRemovedSignal(self.Tag), InstanceUntagged)

		local tagged = CollectionService:GetTagged(self.Tag)
		for _, instance: Instance in pairs(tagged) do
			InstanceTagged(instance)
		end
	end)
end

function Composition:_instansiate(instance)
	local composition = setmetatable({}, self)

	local InstansiateComposition
	function InstansiateComposition(composer, index, composers)
		--local composers = _composition.Composers or {}
		composers = composers or {}
		local lowerComposers = {}

		for _index, _composer in pairs(composers) do
			local handle = _composer.Handle

			local realComposer = handle:_instansiate(composition)
			realComposer[KEY_COMPOSERS] = {}

			local _lowerComposers = InstansiateComposition(realComposer, _index, _composer.Composers)
			for _lowerIndex, _lowerComposer in pairs(_lowerComposers) do
				realComposer[_lowerIndex] = _lowerComposer
				realComposer[KEY_COMPOSERS][_lowerIndex] = _lowerComposer
			end

			if not realComposer then
				continue
			end

			if index then
				realComposer[index] = composer
			end
			lowerComposers[_index] = realComposer
		end

		return lowerComposers
	end

	composition.Instance = instance
	composition[KEY_ANCESTOR] = instance.Parent
	composition[KEY_COMPOSERS] = InstansiateComposition(nil, nil, self[KEY_COMPOSITION])

	return composition
end

function Composition:_construct()
	self[KEY_CONSTRUCTED] = Promise.try(function()
		local resolves = {}
		local composers = self[KEY_COMPOSERS]

		while not TableUtil.IsEmpty(composers) do
			local promises = {}
			local lowerComposers = {}

			for _, composer in pairs(composers) do
				local promise = composer:_construct()

				if not promise then
					continue
				end

				table.insert(promises, promise)
				for _, lowerComposer in pairs(composer[KEY_COMPOSERS]) do
					table.insert(lowerComposers, lowerComposer)
				end
			end

			local _, _resolves = Promise.all(promises):await()
			for _, _resolve in pairs(_resolves) do
				table.insert(resolves, _resolve)
			end

			composers = lowerComposers
		end

		for _, output in ipairs(resolves) do
			if typeof(output) == "function" then
				output()
			else
				warn(output)
			end
		end
	end)

	self[KEY_CONSTRUCTED]:catch(warn)
end

function Composition:_start()
	self[KEY_STARTED] = Promise.try(function()
		self[KEY_CONSTRUCTED]:await()

		local composers = self[KEY_COMPOSERS]

		while not TableUtil.IsEmpty(composers) do
			local promises = {}
			local lowerComposers = {}

			for _, composer in pairs(composers) do
				local promise = composer:_start()

				if not promise then
					continue
				end

				table.insert(promises, promise)
				for _, lowerComposer in pairs(composer[KEY_COMPOSERS]) do
					table.insert(lowerComposers, lowerComposer)
				end
			end

			local status, errors = Promise.all(promises):await()

			if not status then
				for _, error in pairs(errors) do
					warn(error)
				end
			end

			composers = lowerComposers
		end
	end)

	self[KEY_STARTED]:catch(warn)
end

function Composition:_stop()
	self[KEY_STARTED]:andThen(function()
		local composers = self[KEY_COMPOSERS]

		while not TableUtil.IsEmpty(composers) do
			local lowerComposers = {}

			for _, composer in pairs(composers) do
				composer:_stop()

				for _, lowerComposer in pairs(composer[KEY_COMPOSERS]) do
					table.insert(lowerComposers, lowerComposer)
				end
			end

			composers = lowerComposers
		end
	end)
end

function Composition:Destroy()
	self[KEY_TROVE]:Destroy()
end

return Composition
