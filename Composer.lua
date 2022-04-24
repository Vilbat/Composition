local RunService = game:GetService("RunService")

type ExtensionFn = (any) -> ()

type ExtensionShouldFn = (any) -> boolean

type Extension = {
	ShouldExtend: ExtensionShouldFn?,
	ShouldConstruct: ExtensionShouldFn?,
	Constructing: ExtensionFn?,
	Constructed: ExtensionFn?,
	Starting: ExtensionFn?,
	Started: ExtensionFn?,
	Stopping: ExtensionFn?,
	Stopped: ExtensionFn?,
}

type Extensions = { { Extension }? }

local IS_SERVER = RunService:IsServer()
local DEFAULT_TIMEOUT = 60

local Symbol = require(script.Parent.Parent.Symbol)
local Promise = require(script.Parent.Parent.Promise)
local Trove = require(script.Parent.Parent.Trove)
local Signal = require(script.Parent.Parent.Signal)

local KEY_TROVE = Symbol("Trove")

local KEY_EXTENSIONS = Symbol("Extensions")
local KEY_ACTIVE_EXTENSIONS = Symbol("ActiveExtensions")

local KEY_CONSTRUCTED = Symbol("Constructed")
local KEY_STARTED = Symbol("Started")

local KEY_COMPOSITION = Symbol("Composition")
local KEY_COMPOSERS = Symbol("Composers")

local KEY_INST_TO_COMPOSITION = Symbol("InstanceToComposition")

local renderId = 0
local function NextRenderName(): string
	renderId += 1
	return "selfRender" .. tostring(renderId)
end

local function InvokeExtensionFn(self, fnName: string)
	for _, extension in ipairs(self[KEY_ACTIVE_EXTENSIONS]) do
		local fn = extension[fnName]
		if type(fn) == "function" then
			fn(self)
		end
	end
end

local function ShouldConstruct(self): boolean
	for _, extension in ipairs(self[KEY_ACTIVE_EXTENSIONS]) do
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

local function GetActiveExtensions(self, extensionList)
	local activeExtensions = table.create(#extensionList)
	local allActive = true
	for _, extension in ipairs(extensionList) do
		local fn = extension.ShouldExtend
		local shouldExtend = type(fn) ~= "function" or not not fn(self)
		if shouldExtend then
			table.insert(activeExtensions, extension)
		else
			allActive = false
		end
	end
	return if allActive then extensionList else activeExtensions
end

local Composer = {}
Composer.__index = Composer

function Composer.new(extensions: Extensions): table
	local customComposer = {}
	customComposer.__index = customComposer

	customComposer[KEY_TROVE] = Trove.new()

	customComposer[KEY_EXTENSIONS] = extensions or {}

	--customComposer[KEY_CONSTRUCTED] = {}
	--customComposer[KEY_STARTED] = {}

	customComposer[KEY_INST_TO_COMPOSITION] = {}

	customComposer.Constructed = customComposer[KEY_TROVE]:Construct(Signal)
	customComposer.Stopped = customComposer[KEY_TROVE]:Construct(Signal)

	setmetatable(customComposer, Composer)
	return customComposer
end

function Composer:_instansiate(composition, index: string, composers: table?)
	local composer = setmetatable({}, self)

	self[KEY_INST_TO_COMPOSITION][composition.Instance] = composer

	-- Should key composition perhaps be the parent composition instead?
	composer[KEY_COMPOSITION] = composition
	composer[KEY_COMPOSERS] = {}

	composer.Instance = composition.Instance

	composers = composers or {}

	for _index, _composer in pairs(composers) do
		local handle = _composer.Handle
		_composer = handle:_instansiate(composition, _index, _composer.Composers)

		composer[KEY_COMPOSERS][_index] = _composer
		composer[_index] = _composer

		_composer[index] = composer
	end

	return composer
end

function Composer:_construct(): table
	self[KEY_ACTIVE_EXTENSIONS] = GetActiveExtensions(self, self[KEY_EXTENSIONS])

	if not ShouldConstruct(self) then
		return nil
	end

	self[KEY_CONSTRUCTED] = Promise.defer(function(resolve)
		InvokeExtensionFn(self, "Constructing")
		self:Construct()
		InvokeExtensionFn(self, "Constructed")

		local promises = {}
		for _, composer in pairs(self[KEY_COMPOSERS]) do
			local promise = composer:_construct()
			table.insert(promises, promise)
		end

		Promise.allSettled(promises):await()

		resolve()

		self.Constructed:Fire(self)
	end)

	self[KEY_CONSTRUCTED]:catch(warn)

	return self[KEY_CONSTRUCTED]
end

function Composer:_start(): table
	if not self:_getConstructed() then
		return
	end
	if self:_getStarted() then
		return
	end

	self[KEY_STARTED] = Promise.new(function(resolve, reject)
		local status = self[KEY_CONSTRUCTED]:await()

		if not status then
			reject()
			return
		end

		task.defer(function()
		--Promise.defer(function(_resolve)
			InvokeExtensionFn(self, "Starting")
			self:Start()
			InvokeExtensionFn(self, "Started")

			local promises = {}

			for _, composition in pairs(self[KEY_COMPOSERS]) do
				local promise = composition:_start()
				table.insert(promises, promise)
			end

			Promise.allSettled(promises):await()

			local hasHeartbeatUpdate = typeof(self.HeartbeatUpdate) == "function"
			local hasSteppedUpdate = typeof(self.SteppedUpdate) == "function"
			local hasRenderSteppedUpdate = typeof(self.RenderSteppedUpdate) == "function"
			if hasHeartbeatUpdate then
				self._heartbeatUpdate = RunService.Heartbeat:Connect(function(dt)
					self:HeartbeatUpdate(dt)
				end)
			end
			if hasSteppedUpdate then
				self._steppedUpdate = RunService.Stepped:Connect(function(_, dt)
					self:SteppedUpdate(dt)
				end)
			end
			if hasRenderSteppedUpdate and not IS_SERVER then
				if self.RenderPriority then
					self._renderName = NextRenderName()
					RunService:BindToRenderStep(self._renderName, self.RenderPriority, function(dt)
						self:RenderSteppedUpdate(dt)
					end)
				else
					self._renderSteppedUpdate = RunService.RenderStepped:Connect(function(dt)
						self:RenderSteppedUpdate(dt)
					end)
				end
			end

			--_resolve()
		--end):andThen(resolve):catch(reject)
			resolve()
		end)
	end)

	self[KEY_STARTED]:catch(warn)

	return self[KEY_STARTED]
end

function Composer:_stop()
	if not self:_getConstructed() then
		return
	end

	self[KEY_STARTED]
		:finally(function()
			if self._heartbeatUpdate then
				self._heartbeatUpdate:Disconnect()
			end
			if self._steppedUpdate then
				self._steppedUpdate:Disconnect()
			end

			if self._renderSteppedUpdate then
				self._renderSteppedUpdate:Disconnect()
			elseif self._renderName then
				RunService:UnbindFromRenderStep(self._renderName)
			end

			self:Stop()

			for _, composer in pairs(self[KEY_COMPOSERS]) do
				composer:_stop() -- Make this async?
			end

			self.Stopped:Fire()
		end)
		:catch(warn)

	self[KEY_CONSTRUCTED] = nil
	self[KEY_STARTED] = nil
end

function Composer:_getConstructed(): table?
	return self[KEY_CONSTRUCTED]
end

function Composer:_getStarted(): table?
	return self[KEY_STARTED]
end

function Composer:FromInstance(instance: Instance): table?
	local composer = self[KEY_INST_TO_COMPOSITION][instance]

	if not composer then
		return
	end

	--local composition = composer[KEY_COMPOSITION]

	--local promise = self[KEY_CONSTRUCTED][composition]
	local promise = composer[KEY_CONSTRUCTED]

	if not promise then
		return
	end

	if promise:getStatus() ~= Promise.Status.Resolved then
		return
	end

	return composer
end

function Composer:GetComposer(composer: table): table?
	return composer:FromInstance(self.Instance)
end

function Composer:WaitForInstance(instance: Instance, timeout: number?): table
	local composer = self:FromInstance(instance)
	if composer then
		return Promise.resolve(composer)
	end

	return Promise.fromEvent(self.Constructed, function(c)
		local match = c.Instance == instance
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

function Composer:GetAll() end

function Composer:Construct() end

function Composer:Start() end

function Composer:Stop() end

return Composer
