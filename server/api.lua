--[[

	OpenCoins server by PixelToast
	
	Uses apis:
		hook
		webserv
		sql
		crypt
	
	API:
		opencoins.newUser(username,name,password[,ip])
			registers a user, minimum password is 6 chars
		opencoins.user(mt)
			selects user that match things in mt
			i.e. opencoins.user({username="pixel"})
			returns table containing username,name,ip,password,coins
			and a function update, which will update the db with the keys specified
		opencoins.auth(user,password)
			checks password hash
		opencoins.addCoins(user,amount)
			gives user specified amount of coins
		opencoins.newToken(worth[,revert,user])
			creates a new token id
			revert can be used to transfer worth coins back into users account
		opencoins.useToken(id,user)
			transfers the tokens worth into users account
			returns how much it was worth
		opencoins.revertTokens(revert,user)
			reverts all tokens with that revert string back into the account they were created with
			if that account was deleted it uses user instead
		opencoins.deleteUser(user[,tuser])
			deletes user, if tuser is specified it will transfer all the coins to that user
			
	Web API:
		everything returns a lua serialized table
		t[1] is either "success" or "error"
		
		api_newuser.lua?username=pixel&name=Pixel+Toast&password=123456
			registers a user, minimum password is 6 chars
		api_getinfo.lua?(username|name)=(pixel|Pixel+Toast)
			return table with the user's info
			i.e. {"success",{username=pixel,name="PixelToast",coins=9001}}
		api_auth.lua?username=pixel&password=123456
			checks password, errors if invalid
		api_newtoken.lua?username=pixel&password=123456&amount=1337[&revert=bork]
			creates a new token with specified amount
			revert can be used to transfer worth coins back into users account
			returns new token id
		api_usetoken.lua?username=pixel&password=123456&token=5db1fee4b5703808c48078a76768b155b421b210c0761cd6a5d223f4d99f1eaa
			transfers the tokens worth into users account
		api_reverttoken.lua?username=pixel&password=123456&revert=bork
			reverts all tokens with that revert string back into the account they were created with
			if that account was deleted it uses the username specified instead
			returns table of token ids reverted
		api_deleteuser.lua?username=pixel&password=123456[&transferto=ping]
			deletes user, if transferto is specified it will transfer all the coins to that user
			
	Crypto:
		random numbers are generated using OpenSSL, not math.random
		
		passwords are stored as: hex(salt..sha256(salt..password))
		32 byte salt (2^256 combinations)
		
		no signing on user info (sql injection could allow a increase in coins)
		
		tokens are stored as: b64(salt)..":"..worth
		=s in b64 output are removed
]]

reqplugin("sql.lua")
local db=sql.new("opencoins")
opencoins={db=db}
local tokens=db.new("tokens","id","worth","revert","creator")
local users=db.new("users","username","name","ip","password","coins")

function opencoins.newUser(username,name,password,ip)
	if not username:match("^%a[%w_%-~]*$") then
		return false,"Invalid username"
	end
	if not username:match("^%a[%s%w_%-~]*$") or username:match("%s$") then
		return false,"Invalid name"
	end
	if opencoins.user({username=username}) then
		return false,"Username already used"
	end
	if opencoins.user({name=name}) then
		return false,"Name already used"
	end
	if #password<6 then
		return false,"Password too short"
	end
	local salt=crypt.salt(32)
	users.insert({
		username=username,
		name=name,
		password=crypt.tohex(salt)..crypt.hash.sha256(salt..password),
		coins=0,
		ip=ip or "",
	})
	return true
end

hook.new({"command_opencoins","command_coins"},function()
	
end)

hook.new("page_opencoins/api_getinfo.lua",function(cl)
	local dat=cl.postdata or cl.urldata or {}
	if not dat.username and not dat.name then
		return {type="text/plain",data='{"error","Missing name or username field"}'}
	end
	local user=opencoins.user({username=dat.username,name=dat.name})
	if not user then
		return {type="text/plain",data='{"error","No such user"}'}
	end
	local tuser={}
	for k,v in pairs({"username","name","coins"}) do
		tuser[v]=user[v]
	end
	return {type="text/plain",data=serialize({"success",tuser})}
end)

local tusers=setmetatable({},{__mode="v"})

function opencoins.user(mt)
	if type(mt)~="table" then
		mt={username=mt}
	end
	local user=users.select(mt)
	if not user then
		return
	end
	if tusers[user.username] then
		return tusers[user.username]
	end
	user.update=function(...)
		local p={...}
		local vl={}
		for k,v in pairs(p) do
			vl[v]=user[v]
		end
		users.update({username=user.username},vl)
	end
	tusers[user.username]=user
	return user
end

function opencoins.auth(user,pass)
	return crypt.hash.sha256(crypt.fromhex(user.password:sub(1,64))..pass)==user.password:sub(65)
end

hook.new("page_opencoins/api_auth.lua",function(cl)
	local dat=cl.postdata or cl.urldata or {}
	for k,v in pairs({"username","password"}) do
		if not dat[v] then
			return {type="text/plain",data='{"error","Nissing '..v..' field"}'}
		end
	end
	local user=opencoins.user({username=dat.username})
	if not user then
		return {type="text/plain",data='{"error","No such user"}'}
	end
	return {type="text/plain",data=opencoins.auth(user,dat.password) and '{"success"}' or '{"error","Bad password"}'}
end)

function opencoins.addCoins(user,amt)
	user.coins=user.coins+amt
	user.update("coins")
end

function opencoins.newToken(worth,revert,user,force)
	worth=tonumber(worth) or 0
	if not force and (worth<1 or math.floor(worth)~=worth) then
		return false,"Worth must be a integer greater than zero"
	elseif not force and user.coins<worth then
		return false,"Not enough coins"
	end
	local token=tob64(crypt.salt(32)):gsub("=","")..":"..worth
	tokens.insert({
		id=token,
		worth=worth,
		revert=revert or "",
		creator=(user or {}).username or "",
	})
	if user then
		opencoins.addCoins(user,-tonumber(worth))
	end
	return token
end

hook.new("page_opencoins/api_newtoken.lua",function(cl)
	local dat=cl.postdata or cl.urldata or {}
	for k,v in pairs({"username","password","worth"}) do
		if not dat[v] then
			return {type="text/plain",data='{"error","Missing '..v..' field"}'}
		end
	end
	local user=opencoins.user({username=dat.username})
	if not user then
		return {type="text/plain",data='{"error","No such user"}'}
	elseif not opencoins.auth(user,dat.password) then
		return {type="text/plain",data='{"error","Bad password"}'}
	end
	local token,err=opencoins.newToken(dat.worth,dat.revert,user)
	if not token then
		return {type="text/plain",data='{"error","'..err..'"}'}
	end
	return {type="text/plain",data=serialize({"success",token})}
end)

function opencoins.useToken(tk,user)
	local token=tokens.select({id=tk})
	if not token then
		return false,"Invalid token id"
	end
	user.coins=user.coins+token.worth
	user.update("coins")
	tokens.delete({id=tk})
	return token.worth
end

hook.new("page_opencoins/api_usetoken.lua",function(cl)
	local dat=cl.postdata or cl.urldata or {}
	for k,v in pairs({"username","password","token"}) do
		if not dat[v] then
			return {type="text/plain",data='{"error","Missing '..v..' field"}'}
		end
	end
	local user=opencoins.user({username=dat.username})
	if not user then
		return {type="text/plain",data='{"error","No such user"}'}
	elseif not opencoins.auth(user,dat.password) then
		return {type="text/plain",data='{"error","Bad password"}'}
	end
	local worth,err=opencoins.useToken(dat.token,user)
	if not worth then
		return {type="text/plain",data='{"error","'..err..'"}'}
	end
	return {type="text/plain",data=serialize({"success",worth})}
end)

function opencoins.revertTokens(revert,user)
	local out={}
	local usr={}
	for row in tokens.pselect({revert=revert}) do
		table.insert(out,row.id)
		table.insert(usr,row.creator)
	end
	for k,v in pairs(out) do
		opencoins.useToken(v,opencoins.user(usr[k]) or user)
	end
	return out
end

hook.new("page_opencoins/api_reverttoken.lua",function(cl)
	local dat=cl.postdata or cl.urldata or {}
	for k,v in pairs({"username","password","revert"}) do
		if not dat[v] then
			return {type="text/plain",data='{"error","Missing '..v..' field"}'}
		end
	end
	local user=opencoins.user({username=dat.username})
	if not user then
		return {type="text/plain",data='{"error","No such user"}'}
	elseif not opencoins.auth(user,dat.password) then
		return {type="text/plain",data='{"error","Bad password"}'}
	elseif dat.revert=="" then
		return {type="text/plain",data='{"error","Revert cant be blank"}'}
	end
	local out=opencoins.revertTokens(dat.revert,user)
	return {type="text/plain",data=serialize({"success",out})}
end)

function opencoins.deleteUser(user,transferto)
	if transferto then
		tuser.coins=tuser.coins+user.coins
		tuser.update("coins")
	end
	users.delete({username=user.username})
	return true
end

hook.new("page_opencoins/api_deleteuser.lua",function(cl)
	local dat=cl.postdata or cl.urldata or {}
	for k,v in pairs({"username","password"}) do
		if not dat[v] then
			return {type="text/plain",data='{"error","Missing '..v..' field"}'}
		end
	end
	local user=opencoins.user({username=dat.username})
	if not user then
		return {type="text/plain",data='{"error","No such user"}'}
	elseif not opencoins.auth(user,dat.password) then
		return {type="text/plain",data='{"error","Bad password"}'}
	end
	local tuser
	if dat.transferto then
		tuser=opencoins.user({username=dat.transferto})
		if not tuser then
			return {type="text/plain",data='{"error","No such transferto user"}'}
		end
	end
	local res,err=opencoins.deleteUser(user,tuser)
	return {type="text/plain",data=serialize({"success"})}
end)