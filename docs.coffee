R = require 'ramda'
superagent = require 'superagent'
series = require 'run-series'
textload = require './textload.coffee'
postTree = require './post-tree.coffee'
renderHTML = require './renderHTML.coffee'
concatPath = require './concat-path.coffee'
docsFromPaths = require './docs-from-paths.coffee'
parentFromPath = require './parent-from-path.coffee'
superagent = require 'superagent'

class Docs
  constructor: (@user, @repo) ->
  base: 'https://api.github.com'
  headers:
    'Content-Type': 'application/json'

  password: (pass) ->
    @headers['Authorization'] = 'Basic ' + btoa(@user + ':' + pass)

  token: (token) ->
    @headers['Authorization'] = 'token ' + token

  init: (cb) ->
    if @repo == "#{@user}.github.io" or @repo == "#{@user}.github.com"
      @branch = 'master'
    else
      @branch = 'gh-pages'

    @gitStatus =>
      @getTree =>
        @fetchRaw '', cb

  gitStatus: (cb) ->
    superagent.get(@base + "/repos/#{@user}/#{@repo}/branches/#{@branch}")
              .set(@headers)
              .end (err, res) =>
      @master_commit_sha = res.body.commit.sha
      @last_tree_sha = res.body.commit.commit.tree.sha

      cb(null, res.body) if typeof cb == 'function'

  deploy: (cb) ->
    # if there is no deleted doc, we can just fetch the last
    # tree sha and upload the modified files
    if not Object.keys(@deletedDocs).length
      @buildTreeWithModifiedFilesOnly (err, tree) =>
        return console.log err if err
        superagent.post("#{@base}/repos/#{@user}/#{@repo}/git/trees")
                  .set(@headers)
                  .send(
                    tree: tree
                    base_tree: @last_tree_sha
                  )
                  .end (err, res) =>
          if not err and res.body and res.body.sha
            if @last_tree_sha == res.body.sha
              return true

            @commit res.body.sha, cb

    # only if there are deleted docs we shall proceed and fetch
    # everything and build the tree from scratch
    else
      @buildTreeFromScratch (err, tree) =>
        return console.log err if err
        postTree "#{@base}/repos/#{@user}/#{@repo}/git", @headers, tree, (err, new_tree_sha) =>
          # abort if deployment is unchanged / commit empty
          if @last_tree_sha == new_tree_sha
            return true

          @commit new_tree_sha, cb

  commit: (new_tree_sha, cb) ->
    # get a commit message
    message = prompt 'An optional message for the commit:'

    # commit the tree
    superagent.post(@base + "/repos/#{@user}/#{@repo}/git/commits")
              .set(@headers)
              .send(
                message: message or 'P U B L I S H'
                tree: new_tree_sha
                parents: [@master_commit_sha]
              )
              .end (err, res) =>
      new_commit_sha = res.body.sha

      # update the branch with the commit
      superagent.patch(@base + "/repos/#{@user}/#{@repo}/git/refs/heads/#{@branch}")
                .set(@headers)
                .send(sha: new_commit_sha, force: true)
                .end (err, res) =>
        cb(err, res.body)

  buildTreeWithModifiedFilesOnly: (cb) ->
    # grab the complete tree built from scratch
    # and filter it from the unmodified files
    @buildTreeFromScratch (err, tree) =>
      liteTree = []
      for file in tree
        if file.content
          liteTree.push file
      cb null, liteTree

  buildTreeFromScratch: (cb) ->
    @fetchNecessaryDocs (err, results) =>
      # after fetching everything, we make an index of it
      fullDocIndex = R.fromPairs results

      # complete the 'children' props with all the available info
      for _, fullDoc of fullDocIndex
        if fullDoc
          for child in fullDoc.children
            child.path = concatPath [fullDoc.path, child.slug]
            if child.path of fullDocIndex and fullDocIndex[child.path]
              for attr, val of fullDocIndex[child.path]
                child[attr] = val

      # start building the tree
      tree = []
      for path, fullDoc of fullDocIndex
        readmeblob =
          mode: '100644'
          type: 'blob'
          path: concatPath [path, 'README.md']
        htmlblob =
          mode: '100644'
          type: 'blob'
          path: concatPath [path, 'index.html']
        if fullDoc and path of @modifiedDocs
          # only rerender the truly modifiedDocs
          readmeblob.content = @rawCache[path]
          htmlblob.content = renderHTML
            site: {raw: @rawCache['']}
            doc: fullDoc
        else if path of @deletedDocs
          # don't add the deletedDocs to the tree
          continue
        else
          # reuse the existing sha/blob for not docs not modified
          readmeblob.sha = @last_tree_index[concatPath [path, 'README.md']].sha
          htmlblob.sha = @last_tree_index[concatPath [path, 'index.html']].sha

        tree.push readmeblob
        tree.push htmlblob

      # add the files we don't care about
      tree = tree.concat @preserved_tree

      cb null, tree

  fetchNecessaryDocs: (cb) ->
    # this function will run serially and fetch all docs needed to render
    # the modified docs (including parents and siblings)
    fetchAllDocs = R.map ((path) =>
      (callback) =>
        if path of @deletedDocs
          callback null, [path, null]
        else if path of @modifiedDocs or
                parentFromPath(path) of @modifiedDocs
          # to render the modified docs we need all its children
          @getFullDoc path, (err, fullDoc) =>
            callback null, [path, fullDoc]
        else
          callback null, [path, null]
    ), (R.keys @doc_index)

    series fetchAllDocs, cb

  last_tree_index: {}
  preserved_tree: []
  doc_index: {}
  doc_paths: []

  getTree: (cb) ->
    @doc_paths = []
    superagent.get(@base + "/repos/#{@user}/#{@repo}/git/trees/#{@last_tree_sha}?recursive=15")
              .set(@headers)
              .query(branch: @branch)
              .end (err, res) =>
      for file in res.body.tree
        @last_tree_index[file.path] = file

        filename = file.path.split('/').slice(-1)[0]
        if filename == 'README.md'
          # files we actually care about
          @doc_paths.push file.path
        else if filename != 'index.html'
          # files we will just maintain the way they are
          @preserved_tree.push file

      @updateDocIndex()

      cb()

  updateDocIndex: ->
    @doc_index = {}
    for doc in docsFromPaths @doc_paths
      @doc_index[doc.path] = doc

  getFullDoc: (path, cb) ->
    @fetchRaw path, (err, raw) =>
      doc =
        path: path
        raw: raw
        slug: @doc_index[path][0]
        children: @doc_index[path].children
      cb null, doc

  rawCache: {}
  fetchRaw: (path, cb) ->
    cached = @rawCache[path]
    if typeof cached is 'string'
      cb null, cached
    else
      docPath = path
      url = "http://rawgit.com/#{@user}/#{@repo}/#{@branch}/#{path}/README.md"
      textload url, (err, contents) =>
        @rawCache[docPath] = contents
        cb null, contents

  touchAll: (cb) ->
    prefetchDocs = []
    for path of @doc_index
      @modifiedDocs[path] = true
      prefetchDocs.push ((callback) => @fetchRaw path, callback)
    series prefetchDocs, cb

  modifiedDocs: {}
  modifyRaw: (path, raw) ->
    @rawCache[path] = raw
    @modifiedDocs[path] = true
    @modifiedDocs[parentFromPath path] = true

  addDoc: (path) ->
    @rawCache[path] = "---\ntitle: #{path.split('/').slice(-1)[0]}\n---\n\n"
    @modifiedDocs[path] = true
    @modifiedDocs[parentFromPath path] = true
    @doc_paths.push concatPath [path, 'README.md']
    @updateDocIndex()

  deletedDocs: {}
  deleteDoc: (path) ->
    @deletedDocs[path] = true
    @modifiedDocs[parentFromPath path] = true
    pos = @doc_paths.indexOf concatPath [path, 'README.md']
    @doc_paths.splice pos, 1 if pos != -1
    @updateDocIndex()

module.exports = Docs
