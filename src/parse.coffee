# Licensed under the Apache License v2.0.

# A copy of which can be found at the root of this distrubution in
# the file LICENSE-2.0 or at http://www.apache.org/licenses/LICENSE-2.0

S = window.jetzt.streams
I = window.exec.instructions

# Take a dom range and get it's string contents
# This uses window.getSelection() to avoid non-visible (P)CDATA being picked up
range2Str = (range) ->
  sel = window.getSelection()
  if sel.rangeCount
    existing = sel.getRangeAt(0)
  sel.removeAllRanges()
  sel.addRange range
  result = sel.toString()
  sel.removeAllRanges()
  if existing?
    sel.addRange(existing)
  result

# range2str wrapper for dom nodes
elem2str = (elem) ->
  range = window.document.createRange()
  range.selectNodeContents elem
  range2Str range

# get a stream of string matches in a piece of text
regexSectionStream = (regex, text) ->
  new S.Stream ->
    match = regex.exec text
    if match
      string: match[0]
      start: match.index
      end: match.index + match[0].length

filterSectionStream = (sectionStream) ->
  S.map ((section)-> section.type = "filter"; section), sectionStream

ASIDE_NODES =
  "ASIDE" : true
  "IMG"   : true

BREAKER_NODES = {}

breakerNodeTypes = ["LI", "DT", "DD", "IMG", "DIV", "PRE", "TABLE", "BLOCKQUOTE"
                    , "FORM", "PRE", "H1", "H2", "H3", "H4", "H5", "H6"]

for nodeType in breakerNodeTypes
  BREAKER_NODES[nodeType] = true

# get a heirarchical stream mapping nodes to start/end positions in the text
# they contain
nodeSectionStream = (node, text, index = 0) ->
  text = text or elem2str node

  stack = [node]

  nextSection = null

  new S.Stream ->
    if nextSection?
      ret = nextSection
      nextSection = null
      ret
    else if not stack.length
      @die()
    else
      node = stack.pop()

      string = elem2str(node).trim()

      start = text.indexOf string, index

      if node.childNodes?.length
        # push the kids in reverse order !important
        stack.push kid for kid in node.childNodes by -1
      else
        # done with this node, ok to bump index
        index = start + string.length

      result =
        node: node
        type: node.nodeName
        string: string
        start: start
        end: start + string.length

      if node.___jetzt_filter
        result.type = "filter"
      else if node.___jetzt_aside or node.nodeName of ASIDE_NODES
        # for asides we create a pseudo-section in case the actual node
        # has any semantic goodness we'll need later on
        nextSection = result
        result =
          node: node
          type: "aside"
          start: start
          end: nextSection.end

      result


sectionsIntersect = (a, b) ->
  not (a.start > b.end || b.start > a.end)

countLeadingWhitespace = (str) ->
  str.match(/^\s+/)?[0].length or 0

# @string    is the text of the token
# @start     is the index of the token's first character in the original
#            document
# @textEnd   is the index of the character immediately following this token
#            in the original document. Used to indicate progress.
# @startNode is a node, probably a text node, in which the token's first
#            character can be found.
# @offset    is the number of characters from the start of the text contained by
#            @startnode at which this token lies (excluding whitespace)
# @styles    is an array of style sections for to compile the string into an
#            html fragment for display. This will most often be empty.
class AlignedToken
  constructor: (@string, @start, @end, @startNode, @offset, @styles) ->

  select: ->
      # first select the node this token starts on;
      range = window.document.createRange()
      range.selectNodeContents @startNode

      sel = window.getSelection()
      sel.removeAllRanges()
      sel.addRange range

      # get it's parsed text so we know how many whitespace chars it starts with
      base = countLeadingWhitespace sel.toString()

      # now collapse the selection to the start, move it to the token's offset,
      # and then extend it to the end of the token.
      sel.collapseToStart()

      for i in [0...@offset + base]
        sel.modify "move", "forward", "character"

      for i in [0...@string.length]
        sel.modify "extend", "forward", "character"

      sel

# special token for linefeeds.
LINEFEED =
  select: ->
    sel = window.getSelection()
    sel.removeAllRanges()
    sel

# streams are ordered first by start index (ASC), then by end index (DESC)
mergeSectionStreams = (a, b) ->
  asec = a.next()
  bsec = b.next()
  new S.Stream ->
    if asec? and bsec?
      if asec.start < bsec.start
        result = asec
        asec = a.next()
      else if asec.start > bsec.start
        result = bsec
        bsec = b.next()
      else if asec.end < bsec.end
        result = asec
        asec = a.next()
      else
        result = bsec
        bsec = b.next()
    else if asec?
      result = asec
      asec = a.next()
    else if bsec?
      result = bsec
      bsec = b.next()
    else result = @die()

    result


# break types
NONE      = -1   # e.g. <>token
ENCOMPASS = 0    # e.g. <token>
HEAD      = 1    # e.g. <to>ken
TAIL      = 2    # e.g. tok<en>
MIDRIFF   = 3    # e.g. to<k>en

discoverBreakType = (token, section) ->
  if section.start <= token.start
    if section.end <= token.start
      NONE
    else if section.end < token.end
      HEAD
    else
      ENCOMPASS
  else
    if section.start >= token.end
      NONE
    else if section.end < token.end
      MIDRIFF
    else
      TAIL

# breaks a token around the bounds of some section. if filterMode is true,
# does not include the part of the token which was inside the section.
# e.g.
#     say we have the word 'doppelganger' and a section which spans the
#     chracters 'elg'
#
#     with filterMode false, we get back the array like ['dopp', 'elg', 'anger']
#     but with filterMode true, only ['dopp', 'anger']
breakToken = (token, section, filterMode = false, breakType) ->
  breakType = if breakType? then breakType else discoverBreakType token, section

  if breakType is NONE
    [token]
  else if breakType is ENCOMPASS
    if filterMode
      []
    else
      [token]
  else
    s = section
    t = token
    # start and end indices are relative to original text, not the token, so
    # we need to offset them by the start index of the token to do all the
    # string slicing
    offset = (index) -> index - t.start
    result = []

    switch breakType
      when HEAD
        if not filterMode
          result.push
            string : t.string[0...offset(s.end)]
            start  : t.start
            end    : s.end
        result.push
          string : t.string[offset(s.end)..]
          start  : s.end
          end    : t.end
      when TAIL
        result.push
          string : t.string[0...offset(s.start)]
          start  : t.start
          end    : s.start
        if not filterMode
          result.push
            string : t.string[offset(s.start)..]
            start  : s.start
            end    : t.end
      when MIDRIFF
        result.push
          string : t.string[0...offset(s.start)]
          start  : t.start
          end    : s.start
        if not filterMode
          string : t.string[offset(s.start)...offset(s.end)]
          start  : s.start
          end    : s.end
        result.push
          string : t.string[offset(s.end)..]
          start  : s.end
          end    : t.end

    result


wordIsTooLong = (word) ->
  word.length > 13 or word.length > 9 and word.indexOf("-") > -1

splitLongWord = (word) ->
  result = []

  split = (w) ->
    if not wordIsTooLong w
      result.push w
    else
      # try to get individual sections down to 6 characters
      numPartitions = Math.ceil w.length / 7
      partitionLength = Math.floor w.length / numPartitions
      for i in [0...numPartitions-1]
        result.push w[i*partitionLength...(i+1)*partitionLength]

      # and finally the last part
      result.push w[(numPartitions-1)*partitionLength..]

  if word[1...-1].indexOf("-") > -1
    split part for part in word.split("-")
  else
    split word

  result

splitLongToken = (token) ->
  wordParts = splitLongWord token.string
  index = 0
  result = []
  for part in wordParts
    index = token.string.indexOf part, index
    result.push
      string : part + "-"
      start  : index + token.start
      end    : index + token.start + part.length # don't include the '-'
    index += part.length

  ## remove that last dash
  last = result[result.length-1]
  last.string = last.string[...-1]
  result


# map from node names to start/end tag renderers
STYLE_NODES = {}

standardStyleTypes = ["EM", "STRONG", "SUP", "SUB", "S", "CODE"]

for type in standardStyleTypes
  ltype = type.toLowerCase()
  STYLE_NODES[type] =
    startTag: -> "<#{ltype}>"
    endTag: -> "</#{ltype}>"

STYLE_NODES["A"] =
  startTag: (node) -> "<a href='#{node.href}'>"
  endTag: -> "</a>"

STYLE_NODES["pivot"] =
  startTag: -> "<span class='sr-pivot'>"
  endTag: -> "</span>"



# take a stream of token sections and node/filter sections, then smoosh them
# together with a special blend of fresh algorithms and juicy laziness
alignedTokenStream = (tokens, sections) ->

  nextSection = sections.next()

  # this is the stack of sections ordered by start time ASC, then end time DESC
  # it basically represents the DOM tree around the token currently being
  # aligned, but also incorporates filtered sections. Aside sections get dealt
  # with further down the line.
  stack = []

  # when breaking tokens apart for filters, semantic nodes, or word length,
  # we need a way to push them back into the token stream and deal with them as
  # if they are just normal tokens coming in (otherwise too much nasty logic
  # is required). So we do that, but also push the sections back into the
  # relevant stream too, to make sure that nothing gets missed.
  pushbackTokens = (tkns) ->
    tokens = tokens.pushBack tkns

    # also push back sections from stack
    pbSections = stack
    pbSections.push nextSection
    nextSection = pbSections.shift()

    sections = sections.pushBack pbSections

    stack = []

  new S.Stream ->
    if !(token = tokens.next())? or !nextSection?
      @die()
    else if token.string.match /\n+/
      LINEFEED
    else

      # construct the appropriate stack for the token

      # first get rid of any sections which end before the token begins
      while stack.length and stack[stack.length-1].end <= token.start
        stack.pop()

      # now get rid of any sections from the stream which end before the token
      # begins (this only maybe happens after filtering)
      while nextSection? and nextSection.end <= token.start
        nextSection = sections.next()

      if !nextSection?
        return @die()

      # now pull in sections until they start after the token ends
      while nextSection.start < token.end
        stack.push nextSection
        nextSection = sections.next()

      # now apply regex filters and node breakers
      for section in stack
        if section.type is "filter"
          bt = discoverBreakType token, section
          if bt isnt NONE
            if bt isnt ENCOMPASS
              pushbackTokens breakToken token, section, true, bt
            # if bt *is* encompass, we just drop this token
            return @next()
        else if section.type of BREAKER_NODES
          bt = discoverBreakType token, section
          if bt > ENCOMPASS
            pushbackTokens breakToken token, section
            return @next()

      # now do word length splitting
      if wordIsTooLong token.string
        pushbackTokens splitLongToken token
        return @next()

      # I think we're all good on the splitting/filtering front now, so just
      # specialise the sections for the current token, removing the document
      # offset
      tokenSections = []
      for section in stack
        if !section.filter? and section.node?.nodeName of STYLE_NODES
          tokenSections.push
            node  : section.node
            start : section.start - token.start
            end   : Math.min section.end - token.start, token.end - token.start

      # get the start node of the element
      # (this could be merged into the previous loop for performance, but I
      # want the algorithm to be as clear as possible for the moment)
      startSection = null
      for section in stack
        if section.start <= token.start
          if section.node?
            startSection = section
        else break

      if not startSection?
        throw new Error "No start node found. What the jazz?"

      new AlignedToken  token.string
                      , token.start
                      , token.end
                      , startSection.node
                      , token.start - startSection.start
                      , tokenSections



# Semantic nodes are a neat idea. Basically, you get a section associated with
# a dom node or something, and these guys get to compile an onStart and onEnd
# function against that section. These functions get called when the nodes start
# and end respectively, in heirarchical order, and get passed the
# instructionator so they can add instructions for themselves.

# this is a helper function for starting and ending wraps and styles
makeWrap = (left, right) ->
  left: left, right: right

wrapper = (left, right, style) ->
  wrap = makeWrap left, right
  wrap.noClear = true # no need for defensive wrap clearing with these guys
  (sec) ->
    sec.onStart = ($instr) ->
      $instr.pushWrap(wrap)
      style? and $instr.pushStyle(style)
    sec.onEnd = ($instr) ->
      $instr.popWrap(wrap)
      style? and $instr.popStyle(style)

ASIDE_ID = 0

SEMANTIC_NODES =
  BLOCKQUOTE: wrapper "‘", "’"
  H1: wrapper "•••", "•••", "strong"
  H2: wrapper "••", "••", "strong"
  H3: wrapper "•", "•", "strong"
  H4: wrapper "•", "•"
  H5: wrapper "•", "•"
  H6: wrapper "•", "•"

  LI: (sec) ->
    node = sec.node
    parentType = node.parentNode.nodeName
    if parentType is "UL"
      wrapper("•", "")(sec)
    else if parentType is "OL"
      # oh jeez, we have to find its index
      idx = 0
      n = node
      while (n = n.previousSibling)?
        if n.nodeName is "LI"
          idx++

      p = node.parentNode

      wrapper(getOrderedListBullet(idx, p.start, p.type), "")(sec)
    else
      wrapper("", "")(sec)
  
  aside: (sec) ->
    id = ASIDE_ID++
    sec.onStart = ($instr) ->
      $instr.asideStart id, sec.node
    sec.onEnd = ($instr) ->
      $instr.asideEnd id
      $instr.clearWrap()
      $instr.clearStyle()


WRAPS =
  guillemet: makeWrap "«", "»"
  double_quote: makeWrap "“", "”"
  parens: makeWrap "(", ")"

getOrderedListBullet = (idx, start=1, type="1") ->
  return (idx + start) + "."
  # TODO. make this good. It turns out to be super complex if you take negative
  # numbers and li.value/type attributes into account.


instructionStream = (node) ->
  text = elem2str node
  tknregex = /["«»“”\(\)\/—]|--+|\n+|[^\s"“«»”\(\)\/—]+/g

  filterRegex = /\[\d+\]/g # wikipedia citations

  filters = filterSectionStream regexSectionStream filterRegex, text

  tokens = regexSectionStream tknregex, text

  nodes = nodeSectionStream node

  starts = []
  # these ends need to be manually ordered
  ends = []

  pushEnd = (section) ->
    for end, i in ends
      if end.end >= section.end
        ends.splice i, 0, section
        return
    ends.push section
      
  processEnds = (idx, $instr) ->
    while ends.length and ends[0].end <= idx
      ends.shift().onEnd $instr


  # this is not so much a filter as a short circuit to get the wraps and asides
  # so we can create instructions to deal with them. It does filter out asides
  # though.
  grabAsidesAndWraps = (section) ->
    if (compile = SEMANTIC_NODES[section.type])?
      compile section
      starts.push section

    # don't include asides in the stream
    section.type isnt "aside"

  nodes = S.filter grabAsidesAndWraps, nodes

  sections = mergeSectionStreams nodes, filters

  alignedTokens = alignedTokenStream tokens, sections

  nextToken = alignedTokens.next();

  $instr = new Instructionator()

  new S.Stream ->
    if not $instr.needsMore()
      $instr.nextInstruction()
    else if not nextToken?
      if (dregs = $instr.nextInstruction())?
        dregs
      else
        @die()
    else
      while starts.length and starts[0].start <= nextToken.start
        section = starts.shift()
        processEnds section.start, $instr
        section.onStart $instr
        pushEnd section

      processEnds nextToken.start, $instr

      progress = nextToken.end/text.length

      handleToken nextToken, progress, $instr

      processEnds nextToken.end, $instr

      nextToken = alignedTokens.next()
      @next()


handleToken = (tkn, progress, $) ->
  str = tkn.string or "\n\n"
  switch str
    when "“"
      $.spacer()
      $.pushWrap WRAPS.double_quote
      $.modNext "start_clause"
    when "”"
      $.popWrap WRAPS.double_quote
      $.modPrev "end_clause"
      $.spacer()
    when "«"
      $.spacer()
      $.pushWrap WRAPS.guillemet
      $.modNext "start_clause"
    when "»"
      $.popWrap WRAPS.guillemet
      $.modPrev "end_clause"
      $.spacer()
    when "\""
      if double_quote_state
        $.popWrap WRAPS.double_quote
        $.spacer()
        $.modNext "start_clause"
      else
        $.spacer()
        $.pushWrap WRAPS.double_quote
        $.modPrev "end_clause"
      double_quote_state = not double_quote_state
    when "("
      $.spacer()
      $.pushWrap WRAPS.parens
      $.modNext "start_clause"
    when ")"
      $.popWrap WRAPS.parens
      $.modPrev "end_clause"
      $.spacer()
    else
      if str.match(/^(\/|--+|—|–)$/)
        $.modNext "start_clause"
        $.token tkn, progress
        $.modNext "start_clause"
      else if str.match(/[.?!…]+$/)
        $.modNext "end_sentence"
        $.token tkn, progress
        $.modNext "start_sentence"
      else if str.match(/[,;:]$/)
        $.modNext "end_clause"
        $.token tkn, progress
        $.modNext "start_clause"
      else if str.match(/\n+/)
        $.clearWrap()
        $.modPrev "end_paragraph"
        $.spacer()
        $.modNext "start_paragraph"
        double_quote_state = false
      else
        $.token tkn, progress


class Instructionator
  constructor: ->
    @_buffer = []
    @_modifier = "normal"
    @_wraps = []
    @_currentWrap = null
    @_styles = []
    @_currentStyle = null
    @_spacer = null

  nextInstruction: -> @_buffer.shift()

  needsMore: -> @_buffer.length < 10

  modNext: (modifier) ->
    @_modifier = modifier # TODO: use maxModifier once config is ported

  modPrev: (modifier) ->
    for item in @_buffer by -1 when item instanceof I.Word
      item.modifier = modifier # TODO: maxModifier again
      break

  pushWrap: (wrap) ->
    @_wraps.push(wrap)
    @_currentWrap = null

  popWrap: (wrap) ->
    idx = @_wraps.lastIndexOf wrap
    if idx > -1
      @_wraps.splice idx, @_wraps.length
      @_currentWrap = null

  clearWrap: () ->
    @_wraps = @_wraps.filter (w) -> w.noClear
    @_currentWrap = null

  _addWrap: (instr) ->
    if !@_currentWrap?
      left = @_wraps.map((w) -> w.left).join ""
      right = @_wraps.map((w) -> w.right).join ""
      @_currentWrap = left: left, right: right
    instr.wrap = @_currentWrap
    instr

  spacer: ->
    @_spacer = if @_spacer? then I.LONG_SPACE else I.SHORT_SPACE

  pushStyle: (style) ->
    @_styles.push style
    @_currentStyle = null

  popStyle: (style) ->
    idx = @_styles.indexOf style
    if idx > -1
      @_styles.splice idx, @_styles.length
      @_currentStyle = null

  _addStyle: (instr) ->
    if !@_currentStyle?
      @_currentStyle = @_styles.join ""

    instr.style = @_currentStyle
    instr

  clearStyle: ->
    @_styles = []
    @_currentStyle = null

  asideStart: (id, node) ->
    @_buffer.push new I.AsideStart id, node

  asideEnd: (id) ->
    @_buffer.push new I.AsideEnd id

  _emit: (instr) ->
    if @_spacer?
      @_buffer.push @_spacer
      @_spacer = null

    instr.modifier = @_modifier
    @_buffer.push @_addStyle @_addWrap instr

    @_modifier = "normal"

  token: (tkn, progress) ->
    @_emit new I.Word tkn.string, progress, tkn.startNode, tkn.offset






document.addEventListener "DOMContentLoaded", ->
  for junkNode in document.querySelectorAll(".junk")
    junkNode.___jetzt_filter = true
  

  instrs = instructionStream document.body

  window.addEventListener "keydown", ->
    console.log instrs.next()