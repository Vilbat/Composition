-- Based on component by sleitnick

type Composition = { string: table }

type AncestorList = { Instance }

type CompositionConfig = { Tag: string, Composition: Composition, Ancestors: AncestorList }

local CollectionService = game:GetService("CollectionService")

local DEFAULT_ANCESTORS = { workspace, game:GetService("Players") }
local DEFAULT_TIMEOUT = 60

local Trove = require(script.Parent.Trove)
local Symbol = require(script.Parent.Symbol)
local Signal = require(script.Parent.Signal)
local Promise = require(script.Parent.Promise)

local KEY_ANCESTORS = Symbol("Ancestors")
local KEY_TROVE = Symbol("Trove")
local KEY_COMPOSITION = Symbol("Composition")

local KEY_COMPOSITIONS = Symbol("Compositions")

local KEY_COMPOSERS = Symbol("Composers")

local Composition = {}
Composition.__index = Composition

Composition.Composer = require(script.Composer)

function Composition.new(config: CompositionConfig): table
	local customComposition = {}
	customComposition.__index = customComposition

	customComposition[KEY_TROVE] = Trove.new()

	customComposition.Tag = config.Tag

	customComposition[KEY_COMPOSITION] = config.Composition or {}
	customComposition[KEY_ANCESTORS] = config.Ancestors or DEFAULT_ANCESTORS

	customComposition[KEY_COMPOSITIONS] = {}

	customComposition.Constructed = customComposition[KEY_TROVE]:Construct(Signal)

	setmetatable(customComposition, Composition)

	customComposition:_setup()

	return customComposition
end

function Composition:_setup()
	local watchingInstances = {}

	local function TryConstructInstance(instance: Instance)
		if self[KEY_COMPOSITIONS][instance] then
			return
		end

		self[KEY_COMPOSITIONS][instance] = self:_instansiate(instance)
		self[KEY_COMPOSITIONS][instance]:_construct()
		self[KEY_COMPOSITIONS][instance]:_start()

		self.Constructed:Fire(self[KEY_COMPOSITIONS][instance])
	end

	local function TryDeconstuctInstance(instance: Instance)
		if not self[KEY_COMPOSITIONS][instance] then
			return
		end

		self[KEY_COMPOSITIONS][instance]:_stop()
		self[KEY_COMPOSITIONS][instance] = nil
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
			if parent and IsInAncestorList() then
				TryConstructInstance(instance)
			else
				TryDeconstuctInstance(instance)
			end
		end)

		if IsInAncestorList() then
			TryConstructInstance(instance)
		end
	end

	local function InstanceUntagged(instance: Instance)
		local watchHandle = watchingInstances[instance]
		if watchHandle then
			watchHandle:Disconnect()
			watchingInstances[instance] = nil
		end

		TryDeconstuctInstance(instance)
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

function Composition:_instansiate(instance: Instance)
	local composition = setmetatable({}, self)

	composition[KEY_COMPOSERS] = {}
	composition.Instance = instance

	for index, _composition in pairs(self[KEY_COMPOSITION]) do
		local handle = _composition.Handle

		local composer = handle:_instansiate(composition, index, _composition.Composers)
		composition[KEY_COMPOSERS][index] = composer
	end

	return composition
end

function Composition:_construct()
	for _, composer in pairs(self[KEY_COMPOSERS]) do
		if not composer:_getConstructed() then
			composer:_construct()
		end
	end
end

function Composition:_start()
	for _, composer in pairs(self[KEY_COMPOSERS]) do
		if not composer:_getConstructed() then
			continue
		end
		if composer:_getStarted() then
			continue
		end
		composer:_start()
	end
end

function Composition:_stop()
	for _, composer in pairs(self[KEY_COMPOSERS]) do
		if composer:_getConstructed() then
			composer:_stop()
		end
	end
end

function Composition:FromInstance(instance: Instance): table
	return self[KEY_COMPOSITIONS][instance]
end

function Composition:WaitForInstance(instance: Instance, timeout: number?): table
	local composition = self:FromInstance(instance)
	if composition then
		return Promise.resolve(composition)
	end

	return Promise.fromEvent(self.Constructed, function(c)
		local match = c.Instance == instance
		if match then
			composition = c
		end
		return match
	end)
		:andThen(function()
			return composition
		end)
		:timeout(if type(timeout) == "number" then timeout else DEFAULT_TIMEOUT)
end

function Composition:GetComposer(index: string): table
	local composer = self[KEY_COMPOSERS][index]

	local promise = composer:_getConstructed()
	if not promise then
		return
	end

	if promise:getStatus() ~= Promise.Status.Resolved then
		return
	end

	return composer
end

function Composition:WaitForComposer(index: string, timeout: number?): table
	local composer = self:GetComposer(index)
	if composer then
		return Promise.resolve(composer)
	end

	composer = self[KEY_COMPOSERS][index]

	return Promise.fromEvent(composer.Constructed, function(c)
		local match = c == composer
		if match then
			composer = c
		end
		return match
	end)
		:andThen(function()
			return composer
		end)
		:timeout(if type(timeout) == "number" then timeout else DEFAULT_TIMEOUT)
end

--[[
    -- Introduce this?
function Composition:WaitForComposer()
end
--]]

return Composition
