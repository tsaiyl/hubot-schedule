# Description:
#   Schedule a message in both cron-style and datetime-based format pattern
#
# Dependencies:
#   "node-schedule" : "~1.0.0",
#   "cron-parser"   : "~1.0.1"
#
# Configuration:
#   HUBOT_SCHEDULE_DEBUG - set "1" for debug
#   HUBOT_SCHEDULE_DONT_RECEIVE - set "1" if you don't want hubot to be processed by scheduled message
#   HUBOT_SCHEDULE_DENY_EXTERNAL_CONTROL - set "1" if you want to deny scheduling from other rooms
#   HUBOT_SCHEDULE_LIST_REPLACE_TEXT - set JSON object like '{"@":"[at]"}' to configure text replacement used when listing scheduled messages
#
# Commands:
#   hubot schedule - Schedule messages that run on specific frequency or date and time.
#
# Author:
#   matsukaz <matsukaz@gmail.com>, modified by rophy <tsaiyl@tw.ibm.com>

# configuration settings
config =
  debug: process.env.HUBOT_SCHEDULE_DEBUG
  dont_receive: process.env.HUBOT_SCHEDULE_DONT_RECEIVE
  deny_external_control: process.env.HUBOT_SCHEDULE_DENY_EXTERNAL_CONTROL
  list:
    replace_text: JSON.parse(process.env.HUBOT_SCHEDULE_LIST_REPLACE_TEXT ? '{"@":"[@]"}')

scheduler = require('node-schedule')
cronParser = require('cron-parser')
{TextMessage} = require('hubot')
JOBS = {}
JOB_MAX_COUNT = 10000
STORE_KEY = 'hubot_schedule'

module.exports = (robot) ->

  cmds = [
    'schedule add "<datetime pattern>" <message> - Schedule a message that runs on a specific date and time',
    'schedule add "<cron pattern>" <message> - Schedule a message that runs recurrently',
    'schedule delete <id> - Cancel the schedule',
    'schedule update <id> <message> - Update scheduled message',
    'schedule list - List all scheduled messages for current room'
  ]

  robot.brain.on 'loaded', =>
    syncSchedules robot

  if !robot.brain.get(STORE_KEY)
    robot.brain.set(STORE_KEY, {})
  
  showHelp = (msg, cmd) ->
    text = ''
    cmds.forEach (help) ->
      if not cmd or help.indexOf(cmd) == 0
        text += "#{robot.name} #{help}\n"
    msg.send text
  
  parse = (msg) ->
    actionStr = msg.match[1]
    idx = actionStr.indexOf ' '
    if idx == -1
      action = actionStr
    else
      action = actionStr.substring 0, idx
    if actionHandlers[action]
      actionHandlers[action](msg)
    else
      showHelp(msg)

  
  robot.respond /schedule$/i, showHelp
  robot.respond /schedule\s+(.*)$/i, parse

  actionHandlers = {}
  actionHandlers['add'] = (msg) ->
    match = msg.message.text.match /schedule (?:new|add)(?: #(.*))? "(.*?)" ((?:.|\s)*)$/i
    if not match then return showHelp msg, 'schedule add'
    target_room = match[1]

    if not is_blank(target_room) and isRestrictedRoom(target_room, robot, msg)
      return msg.send "Creating schedule for the other room is restricted"
    schedule robot, msg, target_room, match[2], match[3]

  actionHandlers['list'] = (msg) ->
    match = msg.message.text.match /schedule list(?: (all|#.*))?/i
    if not match then return showHelp msg, 'schedule list'
    target_room = match[1]
    if is_blank(target_room) or config.deny_external_control is '1'
      # if target_room is undefined or blank, show schedule for current room
      # room is ignored when HUBOT_SCHEDULE_DENY_EXTERNAL_CONTROL is set to 1
      rooms = [getRoomName(robot, msg.message.user), msg.message.user.reply_to]
    else if target_room == "all"
      show_all = true
    else
      rooms = [target_room[1..]]

    # split jobs into date and cron pattern jobs
    dateJobs = {}
    cronJobs = {}
    for id, job of JOBS
      if show_all or job.user.room in rooms
        if job.pattern instanceof Date
          dateJobs[id] = job
        else
          cronJobs[id] = job

    # sort by date in ascending order
    text = ''
    for id in (Object.keys(dateJobs).sort (a, b) -> new Date(dateJobs[a].pattern) - new Date(dateJobs[b].pattern))
      job = dateJobs[id]
      text += "#{id}: [ #{formatDate(new Date(job.pattern))} ] \##{job.user.room} #{job.message} \n"

    for id, job of cronJobs
      text += "#{id}: [ #{job.pattern} ] \##{job.user.room} #{job.message} \n"

    if !!text.length
      text = text.replace(///#{org_text}///g, replaced_text) for org_text, replaced_text of config.list.replace_text
      msg.send text
    else
      msg.send 'No messages have been scheduled'

  actionHandlers['update'] = (msg) ->
    match = msg.message.text.match /schedule (?:upd|update) (\d+) ((?:.|\s)*)/i
    if not match then return showHelp msg, 'schedule update'
    updateSchedule robot, msg, match[1], match[2]

  actionHandlers['delete'] = (msg) ->
    match = msg.message.text.match /schedule (?:del|delete|remove|cancel) (\d+)/i
    if not match then return showHelp msg, 'schedule delete'
    cancelSchedule robot, msg, match[1]

schedule = (robot, msg, room, pattern, message) ->
  if JOB_MAX_COUNT <= Object.keys(JOBS).length
    return msg.send "Too many scheduled messages"

  id = Math.floor(Math.random() * JOB_MAX_COUNT) while !id? || JOBS[id]
  try
    job = createSchedule robot, id, pattern, msg.message.user, room, message
    if job
      msg.send "#{id}: Schedule created"
    else
      msg.send """
        \"#{pattern}\" is invalid pattern.
        See http://crontab.org/ for cron-style format pattern.
        See http://www.ecma-international.org/ecma-262/5.1/#sec-15.9.1.15 for datetime-based format pattern.
      """
  catch error
    return msg.send error.message


createSchedule = (robot, id, pattern, user, room, message) ->
  if isCronPattern(pattern)
    return createCronSchedule robot, id, pattern, user, room, message

  date = Date.parse(pattern)
  if !isNaN(date)
    if date < Date.now()
      throw new Error "\"#{pattern}\" has already passed"
    return createDatetimeSchedule robot, id, pattern, user, room, message


createCronSchedule = (robot, id, pattern, user, room, message) ->
  startSchedule robot, id, pattern, user, room, message


createDatetimeSchedule = (robot, id, pattern, user, room, message) ->
  startSchedule robot, id, new Date(pattern), user, room, message, () ->
    delete JOBS[id]
    delete robot.brain.get(STORE_KEY)[id]


startSchedule = (robot, id, pattern, user, room, message, cb) ->
  if !room
    room = getRoomName(robot, user)
  job = new Job(id, pattern, user, room, message, cb)
  job.start(robot)
  JOBS[id] = job
  robot.brain.get(STORE_KEY)[id] = job.serialize()


updateSchedule = (robot, msg, id, message) ->
  job = JOBS[id]
  return msg.send "Schedule #{id} not found" if !job

  if isRestrictedRoom(job.user.room, robot, msg)
    return msg.send "Updating schedule for the other room is restricted"

  job.message = message
  robot.brain.get(STORE_KEY)[id] = job.serialize()
  msg.send "#{id}: Scheduled message updated"


cancelSchedule = (robot, msg, id) ->
  job = JOBS[id]
  return msg.send "#{id}: Schedule not found" if !job

  if isRestrictedRoom(job.user.room, robot, msg)
    return msg.send "Canceling schedule for the other room is restricted"

  job.cancel()
  delete JOBS[id]
  delete robot.brain.get(STORE_KEY)[id]
  msg.send "#{id}: Schedule canceled"


syncSchedules = (robot) ->
  if !robot.brain.get(STORE_KEY)
    robot.brain.set(STORE_KEY, {})

  nonCachedSchedules = difference(robot.brain.get(STORE_KEY), JOBS)
  for own id, job of nonCachedSchedules
    scheduleFromBrain robot, id, job...

  nonStoredSchedules = difference(JOBS, robot.brain.get(STORE_KEY))
  for own id, job of nonStoredSchedules
    storeScheduleInBrain robot, id, job


scheduleFromBrain = (robot, id, pattern, user, message) ->
  envelope = user: user, room: user.room
  try
    createSchedule robot, id, pattern, user, user.room, message
  catch error
    robot.send envelope, "#{id}: Failed to schedule from brain. [#{error.message}]" if config.debug is '1'
    return delete robot.brain.get(STORE_KEY)[id]

  robot.send envelope, "#{id} scheduled from brain" if config.debug is '1'


storeScheduleInBrain = (robot, id, job) ->
  robot.brain.get(STORE_KEY)[id] = job.serialize()

  envelope = user: job.user, room: job.user.room
  robot.send envelope, "#{id}: Schedule stored in brain asynchronously" if config.debug is '1'


difference = (obj1 = {}, obj2 = {}) ->
  diff = {}
  for id, job of obj1
    diff[id] = job if id !of obj2
  return diff


isCronPattern = (pattern) ->
  errors = cronParser.parseString(pattern).errors
  return !Object.keys(errors).length


is_blank = (s) -> !s?.trim()


is_empty = (o) -> Object.keys(o).length == 0


isRestrictedRoom = (target_room, robot, msg) ->
  if config.deny_external_control is '1'
    if target_room not in [getRoomName(robot, msg.message.user), msg.message.user.reply_to]
      return true
  return false


toTwoDigits = (num) ->
  ('0' + num).slice(-2)


formatDate = (date) ->
  offset = -date.getTimezoneOffset();
  sign = ' GMT+'
  if offset < 0
    offset = -offset
    sign = ' GMT-'
  [date.getFullYear(), toTwoDigits(date.getMonth()+1), toTwoDigits(date.getDate())].join('-') + ' ' + date.toLocaleTimeString() + sign + toTwoDigits(offset / 60) + ':' + toTwoDigits(offset % 60);


getRoomName = (robot, user) ->
  return user.room


class Job
  constructor: (id, pattern, user, room, message, cb) ->
    @id = id
    @pattern = pattern
    @user = { room: (room || user.room) }
    @user[k] = v for k,v of user when k in ['id','team_id','name'] # copy only needed properties
    @message = message
    @cb = cb
    @job

  start: (robot) ->
    @job = scheduler.scheduleJob(@pattern, =>
      envelope = user: @user, room: @user.room
      robot.send envelope, @message
      robot.adapter.receive new TextMessage(@user, @message) unless config.dont_receive is '1'
      @cb?()
    )

  cancel: ->
    scheduler.cancelJob @job if @job
    @cb?()

  serialize: ->
    [@pattern, @user, @message]
