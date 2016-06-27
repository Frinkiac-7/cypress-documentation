require("../spec_helper")

_             = require("lodash")
rp            = require("request-promise")
dns           = require("dns")
http          = require("http")
glob          = require("glob")
path          = require("path")
str           = require("underscore.string")
coffee        = require("coffee-script")
Promise       = require("bluebird")
config        = require("#{root}lib/config")
Server        = require("#{root}lib/server")
files         = require("#{root}lib/controllers/files")
CacheBuster   = require("#{root}lib/util/cache_buster")
Fixtures      = require("#{root}spec/server/helpers/fixtures")

## force supertest-session to use supertest-as-promised, hah
Session       = proxyquire("supertest-session", {supertest: supertest})

glob = Promise.promisify(glob)

removeWhitespace = (c) ->
  c = str.clean(c)
  c = str.lines(c).join(" ")
  c

describe "Routes", ->
  beforeEach ->
    @sandbox.stub(CacheBuster, "get").returns("-123")

    nock.enableNetConnect()

    @setup = (initialUrl, obj = {}) =>
      if _.isObject(initialUrl)
        obj = initialUrl
        initialUrl = null

      ## get all the config defaults
      ## and allow us to override them
      ## for each test
      cfg = config.set(obj)

      ## use a jar for each test
      ## but reset it automatically
      ## between test
      jar = rp.jar()

      ## use a custom request promise
      ## to automatically backfill these
      ## options including our proxy
      @rp = (options = {}) =>
        if _.isString(options)
          url = options
          options = {}

        _.defaults options,
          url: url
          proxy: @proxy
          jar: jar
          simple: false
          followRedirect: false
          resolveWithFullResponse: true

        rp(options)

      open = =>
        Server().open(cfg)
        .then (server) =>
          @server = server

          if initialUrl
            @server._onDomainSet(initialUrl)

          @srv = server.getHttpServer()

          @session = new (Session({app: @srv}))

          @proxy = "http://localhost:" + @srv.address().port

      if @server
        @server.close()
        .then(open)
      else
        open()

  afterEach ->
    nock.cleanAll()
    @session.destroy()
    @server.close()

  context "GET /", ->
    beforeEach ->
      @setup()

    it "redirects to config.clientRoute without a _remoteOrigin", ->
      @rp("http://localhost:2020/")
      .then (res) ->
        expect(res.statusCode).to.eq(302)
        expect(res.headers.location).to.eq "/__/"

    ## this tests a situation where we open our browser in another browser
    ## without proxy mode set
    it "redirects to config.clientRoute without a _remoteOrigin and without a proxy", ->
      @rp({
        url: "http://localhost:2020/"
        proxy: null
      })
      .then (res) ->
        expect(res.statusCode).to.eq(302)
        expect(res.headers.location).to.eq "/__/"

    it "does not redirect with _remoteOrigin set", ->
      @setup("http://www.github.com")
      .then =>
        nock(@server._remoteOrigin)
        .get("/")
        .reply(200, "<html></html>", {
          "Content-Type": "text/html"
        })

        @rp({
          url: "http://www.github.com/"
          headers: {
            "Cookie": "__cypress.initial=true"
          }
        })
        .then (res) ->
          expect(res.statusCode).to.eq(200)
          expect(res.body).to.eq("<html></html>")

  context "GET /__", ->
    beforeEach ->
      @setup({projectName: "foobarbaz"})

    it "routes config.clientRoute to serve cypress client app html", ->
      @rp("http://localhost:2020/__")
      .then (res) ->
        expect(res.statusCode).to.eq(200)
        expect(res.body).to.match(/App.start\(.+\)/)

    it "sets title to projectName", ->
      @rp("http://localhost:2020/__")
      .then (res) ->
        expect(res.statusCode).to.eq(200)
        expect(res.body).to.include("<title>foobarbaz</title>")

    it "omits x-powered-by", ->
      @rp("http://localhost:2020/__")
      .then (res) ->
        expect(res.statusCode).to.eq(200)
        expect(res.headers["x-powered-by"]).not.to.exist

  context "GET /__cypress/files", ->
    beforeEach ->
      Fixtures.scaffold("todos")
      Fixtures.scaffold("ids")

    afterEach ->
      Fixtures.remove("todos")
      Fixtures.remove("ids")

    describe "todos with specific configuration", ->
      beforeEach ->
        @setup({
          projectRoot: Fixtures.projectPath("todos")
          config: {
            integrationFolder: "tests"
            fixturesFolder: "tests/_fixtures"
            supportFolder: "tests/_support"
            javascripts: ["tests/etc/**/*"]
          }
        })

      it "returns base json file path objects", ->
        ## this should omit any _fixture files, _support files and javascripts

        glob(path.join(Fixtures.projectPath("todos"), "tests", "_fixtures", "**", "*"))
        .then (files) =>
          ## make sure there are fixtures in here!
          expect(files.length).to.be.gt(0)

          glob(path.join(Fixtures.projectPath("todos"), "tests", "_support", "**", "*"))
          .then (files) =>
            ## make sure there are support files in here!
            expect(files.length).to.be.gt(0)

            @rp({
              url: "http://localhost:2020/__cypress/files"
              json: true
            })
            .then (res) ->
              expect(res.statusCode).to.eq(200)
              expect(res.body).to.deep.eq([
                { name: "integration/sub/sub_test.coffee" }
                { name: "integration/test1.js" }
                { name: "integration/test2.coffee" }
              ])

    describe "ids with regular configuration", ->
      it "returns test files as json ignoring *.hot-update.js", ->
        @setup({
          projectRoot: Fixtures.projectPath("ids")
        })

        @rp({
          url: "http://localhost:2020/__cypress/files"
          json: true
        })
        .then (res) ->
          expect(res.statusCode).to.eq(200)
          expect(res.body).to.deep.eq([
            { name: "integration/bar.js" }
            { name: "integration/foo.coffee" }
            { name: "integration/nested/tmp.js" }
            { name: "integration/noop.coffee" }
          ])

      it "can ignore other files as well", ->
        @setup({
          projectRoot: Fixtures.projectPath("ids")
          config: {
            ignoreTestFiles: ["**/bar.js", "foo.coffee", "**/*.hot-update.js", "**/nested/*"]
          }
        })

        @rp({
          url: "http://localhost:2020/__cypress/files"
          json: true
        })
        .then (res) ->
          expect(res.statusCode).to.eq(200)
          expect(res.body).to.deep.eq([
            { name: "integration/noop.coffee" }
          ])

  context "GET /__cypress/tests", ->
    describe "todos", ->
      beforeEach ->
        Fixtures.scaffold("todos")

        @setup({
          projectRoot: Fixtures.projectPath("todos")
          config: {
            integrationFolder: "tests"
            javascripts: ["support/spec_helper.coffee"]
          }
        })

      afterEach ->
        Fixtures.remove("todos")

      it "processes sub/sub_test.coffee spec", ->
        file = Fixtures.get("projects/todos/tests/sub/sub_test.coffee")
        file = coffee.compile(file)

        @rp("http://localhost:2020/__cypress/tests?p=tests/sub/sub_test.coffee")
        .then (res) ->
          expect(res.statusCode).to.eq(200)
          expect(res.body).to.eq file

      it "processes support/spec_helper.coffee javascripts", ->
        file = Fixtures.get("projects/todos/lib/my_coffee.coffee")
        file = coffee.compile(file)

        @rp("http://localhost:2020/__cypress/tests?p=lib/my_coffee.coffee")
        .then (res) ->
          expect(res.statusCode).to.eq(200)
          expect(res.body).to.eq file

    describe "no-server", ->
      beforeEach ->
        Fixtures.scaffold("no-server")

        @setup({
          projectRoot: Fixtures.projectPath("no-server")
          config: {
            integrationFolder: "my-tests"
            javascripts: ["helpers/includes.js"]
          }
        })

      afterEach ->
        Fixtures.remove("no-server")

      it "processes my-tests/test1.js spec", ->
        file = Fixtures.get("projects/no-server/my-tests/test1.js")

        @rp("http://localhost:2020/__cypress/tests?p=my-tests/test1.js")
        .then (res) ->
          expect(res.statusCode).to.eq(200)
          expect(res.body).to.eq file

      it "processes helpers/includes.js javascripts", ->
        file = Fixtures.get("projects/no-server/helpers/includes.js")

        @rp("http://localhost:2020/__cypress/tests?p=helpers/includes.js")
        .then (res) ->
          expect(res.statusCode).to.eq(200)
          expect(res.body).to.eq file

  context "ALL /__cypress/xhrs/*", ->
    beforeEach ->
      @setup()

    describe "delay", ->
      it "can set delay to 10ms", ->
        delay = @sandbox.spy(Promise, "delay")

        @rp({
          url: "http://localhost:2020/__cypress/xhrs/users/1"
          headers: {
            "x-cypress-delay": "10"
          }
        })
        .then (res) ->
          expect(res.statusCode).to.eq(200)
          expect(delay).to.be.calledWith(10)

      it "does not call Promise.delay when no delay", ->
        delay = @sandbox.spy(Promise, "delay")

        @rp("http://localhost:2020/__cypress/xhrs/users/1")
        .then (res) ->
          expect(res.statusCode).to.eq(200)
          expect(delay).not.to.be.called

    describe "status", ->
      it "can set status", ->
        @rp({
          url: "http://localhost:2020/__cypress/xhrs/users/1"
          headers: {
            "x-cypress-status": "401"
          }
        })
        .then (res) ->
          expect(res.statusCode).to.eq(401)

    describe "headers", ->
      it "can set headers", ->
        headers = JSON.stringify({
          "x-token": "123"
          "content-type": "text/plain"
        })

        @rp({
          url: "http://localhost:2020/__cypress/xhrs/users/1"
          headers: {
            "x-cypress-headers": headers
          }
        })
        .then (res) ->
          expect(res.statusCode).to.eq(200)
          expect(res.headers["content-type"]).to.match(/text\/plain/)
          expect(res.headers["x-token"]).to.eq("123")

      it "sets headers from response type", ->
        headers = JSON.stringify({
          "x-token": "123"
        })

        @rp({
          url: "http://localhost:2020/__cypress/xhrs/users/1"
          json: true
          headers: {
            "x-cypress-headers": headers
            "x-cypress-response": JSON.stringify({foo: "bar"})
          }
        })
        .then (res) ->
          expect(res.statusCode).to.eq(200)
          expect(res.headers["content-type"]).to.match(/application\/json/)
          expect(res.headers["x-token"]).to.eq("123")
          expect(res.body).to.deep.eq({foo: "bar"})

    describe "response", ->
      it "sets response to json", ->
        @rp({
          url: "http://localhost:2020/__cypress/xhrs/users/1"
          json: true
          headers: {
            "x-cypress-response": JSON.stringify([1,2,3])
          }
        })
        .then (res) ->
          expect(res.statusCode).to.eq(200)
          expect(res.headers["content-type"]).to.match(/application\/json/)
          expect(res.body).to.deep.eq([1,2,3])

      it "sets response to text/html", ->
        @rp({
          url: "http://localhost:2020/__cypress/xhrs/users/1"
          headers: {
            "x-cypress-response": "<html>foo</html>"
          }
        })
        .then (res) ->
          expect(res.statusCode).to.eq(200)
          expect(res.headers["content-type"]).to.match(/text\/html/)
          expect(res.body).to.eq("<html>foo</html>")

      it "sets response to text/plain", ->
        @rp({
          url: "http://localhost:2020/__cypress/xhrs/users/1"
          headers: {
            "x-cypress-response": "foobarbaz"
          }
        })
        .then (res) ->
          expect(res.statusCode).to.eq(200)
          expect(res.headers["content-type"]).to.match(/text\/plain/)
          expect(res.body).to.eq("foobarbaz")

      it "sets response to text/plain on empty response", ->
        @rp({
          url: "http://localhost:2020/__cypress/xhrs/users/1"
          headers: {
            "x-cypress-response": ""
          }
        })
        .then (res) ->
          expect(res.statusCode).to.eq(200)
          expect(res.headers["content-type"]).to.match(/text\/plain/)
          expect(res.body).to.eq("")

      it "decodes responses", ->
        response = encodeURI(JSON.stringify({
          "test": "We’ll"
        }))

        @rp({
          url: "http://localhost:2020/__cypress/xhrs/users/1"
          json: true
          headers: {
            "x-cypress-response": response
          }
        })
        .then (res) ->
          expect(res.statusCode).to.eq(200)
          expect(res.body).to.deep.eq({test: "We’ll"})

      context "fixture", ->
        beforeEach ->
          Fixtures.scaffold("todos")

          @setup({
            projectRoot: Fixtures.projectPath("todos")
            config: {
              integrationFolder: "tests"
              fixturesFolder: "tests/_fixtures"
            }
          })

        afterEach ->
          Fixtures.remove("todos")

        it "returns fixture contents", ->
          @rp({
            url: "http://localhost:2020/__cypress/xhrs/bar"
            json: true
            headers: {
              "x-cypress-response": "fixture:foo"
            }
          })
          .then (res) ->
            expect(res.statusCode).to.eq(200)
            expect(res.headers["content-type"]).to.match(/application\/json/)
            expect(res.body).to.deep.eq([{json: true}])

        it "returns __error on fixture errors", ->
          @rp({
            url: "http://localhost:2020/__cypress/xhrs/bar"
            json: true
            headers: {
              "x-cypress-response": "fixture:bad_json"
            }
          })
          .then (res) ->
            expect(res.statusCode).to.eq(400)
            expect(res.headers["content-type"]).to.match(/application\/json/)
            expect(res.body.__error).to.include("'bad_json' is not valid JSON.")

      context "PUT", ->
        it "can issue PUT requests", ->
          @rp({
            method: "put"
            url: "http://localhost:2020/__cypress/xhrs/users/1"
            json: true
            body: {
              name: "brian"
            }
            headers: {
              "x-cypress-response": JSON.stringify({id: 123, name: "brian"})
            }
          })
          .then (res) ->
            expect(res.statusCode).to.eq(200)
            expect(res.headers["content-type"]).to.match(/application\/json/)
            expect(res.body).to.deep.eq({id: 123, name: "brian"})

      context "POST", ->
        it "can issue POST requests", ->
          @rp({
            method: "post"
            url: "http://localhost:2020/__cypress/xhrs/users/1"
            json: true
            body: {
              name: "brian"
            }
            headers: {
              "x-cypress-response": JSON.stringify({id: 123, name: "brian"})
            }
          })
          .then (res) ->
            expect(res.statusCode).to.eq(200)
            expect(res.headers["content-type"]).to.match(/application\/json/)
            expect(res.body).to.deep.eq({id: 123, name: "brian"})

      context "HEAD", ->
        it "can issue PUT requests", ->
          @rp({
            method: "head"
            url: "http://localhost:2020/__cypress/xhrs/users/1"
          })
          .then (res) ->
            expect(res.statusCode).to.eq(200)
            expect(res.headers["content-type"]).to.match(/text\/plain/)

      context "DELETE", ->
        it "can issue DELETE requests", ->
          @rp({
            method: "delete"
            url: "http://localhost:2020/__cypress/xhrs/users/1"
          })
          .then (res) ->
            expect(res.statusCode).to.eq(200)
            expect(res.headers["content-type"]).to.match(/text\/plain/)

    # describe.only "maximum header size", ->
    #   ## https://github.com/cypress-io/cypress/issues/76
    #   it "does not bomb on huge headers", ->
    #     json = Fixtures.get("server/really_big_json.json")

    #     supertest(@srv)
    #       .get("/__cypress/xhrs/users")
    #       .set("x-cypress-response", json)
    #       .set("x-cypress-response-2", json)
    #       .expect(200)
    #       .expect("Content-Type", /application\/json/)
    #       .expect(JSON.parse(json))

  context "GET /__cypress/iframes/*", ->
    beforeEach ->
      Fixtures.scaffold("automations")
      Fixtures.scaffold("todos")
      Fixtures.scaffold("no-server")
      Fixtures.scaffold("ids")

    afterEach ->
      files.reset()

      Fixtures.remove("todos")
      Fixtures.remove("no-server")
      Fixtures.remove("ids")

    describe "usage", ->
      beforeEach ->
        @setup({
          projectRoot: Fixtures.projectPath("ids")
          projectName: "foobarbaz"
        })

      it "counts specs, exampleSpec, and allSpecs", ->
        @rp("http://localhost:2020/__cypress/iframes/integration/foo.coffee")
        .then (res) =>
          expect(res.statusCode).to.eq(200)
          expect(files.getStats()).to.deep.eq({
            numRuns: 1
            allSpecs: false
            exampleSpec: false
            projectName: "foobarbaz"
          })
        .then =>
          @rp("http://localhost:2020/__cypress/iframes/__all")
          .then (res) =>
            expect(res.statusCode).to.eq(200)
            expect(files.getStats()).to.deep.eq({
              numRuns: 2
              allSpecs: true
              exampleSpec: false
              projectName: "foobarbaz"
            })
        .then =>
          @rp("http://localhost:2020/__cypress/iframes/integration/example_spec.js")
          .then (res) ->
            expect(res.statusCode).to.eq(200)
            expect(files.getStats()).to.deep.eq({
              numRuns: 3
              allSpecs: true
              exampleSpec: true
              projectName: "foobarbaz"
            })

    describe "todos", ->
      beforeEach ->
        @setup({
          projectRoot: Fixtures.projectPath("todos")
          config: {
            integrationFolder: "tests"
            fixturesFolder: "tests/_fixtures"
            supportFolder: "tests/_support"
            javascripts: ["tests/etc/etc.js"]
          }
        })

      it "renders iframe with variables passed in", ->
        contents = removeWhitespace Fixtures.get("server/expected_todos_iframe.html")

        @rp("http://localhost:2020/__cypress/iframes/integration/test2.coffee")
        .then (res) ->
          expect(res.statusCode).to.eq(200)

          body = removeWhitespace(res.body)
          expect(body).to.eq contents

      it "can send back all tests", ->
        contents = removeWhitespace Fixtures.get("server/expected_todos_all_tests_iframe.html")

        @rp("http://localhost:2020/__cypress/iframes/__all")
        .then (res) ->
          expect(res.statusCode).to.eq(200)

          body = removeWhitespace(res.body)
          expect(body).to.eq contents

    describe "no-server", ->
      beforeEach ->
        @setup({
          projectRoot: Fixtures.projectPath("no-server")
          config: {
            integrationFolder: "my-tests"
            javascripts: ["helpers/includes.js"]
            fileServerFolder: "foo"
          }
        })

      it "renders iframe with variables passed in", ->
        contents = removeWhitespace Fixtures.get("server/expected_no_server_iframe.html")

        @rp("http://localhost:2020/__cypress/iframes/integration/test1.js")
        .then (res) ->
          expect(res.statusCode).to.eq(200)

          body = removeWhitespace(res.body)
          expect(body).to.eq contents

    describe "automations", ->
      beforeEach ->
        @setup({
          projectRoot: Fixtures.projectPath("automations")
          config: {
            integrationFolder: "cypress/integration"
            supportFolder: "cypress/support"
          }
        })

      it "omits support directories", ->
        contents = removeWhitespace Fixtures.get("server/expected_automations_iframe.html")

        @rp("http://localhost:2020/__cypress/iframes/integration/app_spec.coffee")
        .then (res) ->
          expect(res.statusCode).to.eq(200)

          body = removeWhitespace(res.body)
          expect(body).to.eq contents

    describe "ids", ->
      beforeEach ->
        @setup({
          projectRoot: Fixtures.projectPath("ids")
        })

      it "renders iframe with variables passed in", ->
        contents = removeWhitespace Fixtures.get("server/expected_ids_iframe.html")

        @rp("http://localhost:2020/__cypress/iframes/integration/foo.coffee")
        .then (res) ->
          expect(res.statusCode).to.eq(200)


          body = removeWhitespace(res.body)
          expect(body).to.eq contents

      it "can send back all tests", ->
        contents = removeWhitespace Fixtures.get("server/expected_ids_all_tests_iframe.html")

        @rp("http://localhost:2020/__cypress/iframes/__all")
        .then (res) ->
          expect(res.statusCode).to.eq(200)

          body = removeWhitespace(res.body)
          expect(body).to.eq contents

  context "GET *", ->
    context "basic request", ->
      beforeEach ->
        @setup("http://www.github.com")

      it "basic 200 html response", ->
        nock(@server._remoteOrigin)
        .get("/")
        .reply 200, "hello from bar!", {
          "Content-Type": "text/html"
        }

        @rp({
          url: "http://www.github.com/"
          headers: {
            "Cookie": "__cypress.initial=true"
          }
        })
        .then (res) ->
          expect(res.statusCode).to.eq(200)
          expect(res.body).to.eq("hello from bar!")

    context "gzip", ->
      beforeEach ->
        @setup("http://www.github.com")

      it "does not send accept-encoding headers when initial=true", ->
        nock(@server._remoteOrigin)
        .get("/gzip")
        .matchHeader "accept-encoding", (val) ->
          val isnt "gzip"
        # .replyWithFile 200, Fixtures.path("server/gzip.html.gz"), {
        #   "Content-Type": "text/html"
        #   "Content-Encoding": "gzip"
        # }
        .reply(200)

        @rp({
          url: "http://www.github.com/gzip"
          gzip: true
          headers: {
            "Cookie": "__cypress.initial=true"
          }
        })
        .then (res) ->
          expect(res.statusCode).to.eq(200)

      it "does send accept-encoding headers when initial=false", ->
        nock(@server._remoteOrigin)
        .get("/gzip")
        .matchHeader("accept-encoding", /gzip/)
        .reply(200)

        @rp({
          url: "http://www.github.com/gzip"
          gzip: true
          headers: {
            "Cookie": "__cypress.initial=false"
          }
        })
        .then (res) ->
          expect(res.statusCode).to.eq(200)

      ## okay so the reason this test is valuable is the following:
      ## superagent WILL automatically decode the requests if content-encoding: gzip
      ## if our response was NOT a gzip, then it would explode
      ## because its properly gzipped then our response is unzipped and we get the
      ## normal string content.
      it "does not UNZIP gzipped responses when streaming back the response", ->
        nock(@server._remoteOrigin)
        .get("/gzip")
        .matchHeader("accept-encoding", /gzip/)
        .replyWithFile(200, Fixtures.path("server/gzip.html.gz"), {
          "Content-Type": "text/html"
          "Content-Encoding": "gzip"
        })

        @rp({
          url: "http://www.github.com/gzip"
          gzip: true
          headers: {
            "Cookie": "__cypress.initial=false"
          }
        })
        .then (res) ->
          expect(res.statusCode).to.eq(200)
          expect(res.body).to.eq("<html>gzip</html>")

    context "304 Not Modified", ->
      beforeEach ->
        @setup("http://localhost:8080")

      it "sends back a 304", ->
        nock(@server._remoteOrigin)
        .get("/assets/app.js")
        .reply(304)

        @rp({
          url: "http://localhost:8080/assets/app.js"
          headers: {
            "Cookie": "__cypress.initial=false"
          }
        })
        .then (res) ->
          expect(res.statusCode).to.eq(304)

    context "redirects", ->
      beforeEach ->
        @setup("http://getbootstrap.com")

      it "passes the location header through", ->
        nock(@server._remoteOrigin)
        .get("/foo")
        .reply 302, undefined, {
          "Location": "/"
        }
        .get("/")
        .reply 200, "<html></html", {
          "Content-Type": "text/html"
        }

        @rp({
          url: "http://getbootstrap.com/foo"
          headers: {
            "Cookie": "__cypress.initial=true"
          }
        })
        .then (res) ->
          expect(res.statusCode).to.eq(302)
          expect(res.headers["set-cookie"]).to.include("__cypress.initial=true; Path=/")
          expect(res.headers["location"]).to.eq("/")

      ## this fixes improper url merge where we took query params
      ## and added them needlessly
      it "doesnt redirect with query params or hashes which werent in location header", ->
        nock(@server._remoteOrigin)
        .get("/foo?bar=baz")
        .reply 302, undefined, {
          "Location": "/css"
        }

        @rp({
          url: "http://getbootstrap.com/foo?bar=baz"
          headers: {
            "Cookie": "__cypress.initial=true"
          }
        })
        .then (res) =>
          expect(res.statusCode).to.eq(302)
          expect(res.headers["set-cookie"]).to.include("__cypress.initial=true; Path=/")
          expect(res.headers["location"]).to.eq("/css")

      it "does redirect with query params if location header includes them", ->
        nock(@server._remoteOrigin)
        .get("/foo?bar=baz")
        .reply 302, undefined, {
          "Location": "/css?q=search"
        }
        .get("/")
        .reply 200, "<html></html", {
          "Content-Type": "text/html"
        }

        @rp({
          url: "http://getbootstrap.com/foo?bar=baz"
          headers: {
            "Cookie": "__cypress.initial=true"
          }
        })
        .then (res) ->
          expect(res.statusCode).to.eq(302)
          expect(res.headers["set-cookie"]).to.include("__cypress.initial=true; Path=/")
          expect(res.headers["location"]).to.eq("/css?q=search")

      it "does redirect with query params to external domain if location header includes them", ->
        nock(@server._remoteOrigin)
        .get("/foo?bar=baz")
        .reply 302, undefined, {
          "Location": "https://www.google.com/search?q=cypress"
        }
        .get("/")
        .reply 200, "<html></html", {
          "Content-Type": "text/html"
        }

        @rp({
          url: "http://getbootstrap.com/foo?bar=baz"
          headers: {
            "Cookie": "__cypress.initial=true"
          }
        })
        .then (res) ->
          expect(res.statusCode).to.eq(302)
          expect(res.headers["set-cookie"]).to.include("__cypress.initial=true; Path=/")
          expect(res.headers["location"]).to.eq("https://www.google.com/search?q=cypress")

      it "sets cookies and removes __cypress.initial when initial is originally false", ->
        nock(@server._remoteOrigin)
        .get("/css")
        .reply 302, undefined, {
          "Set-Cookie": "foo=bar; Path=/"
          "Location": "/css/"
        }

        @rp({
          url: "http://getbootstrap.com/css"
          headers: {
            "Cookie": "__cypress.initial=false"
          }
        })
        .then (res) ->
          expect(res.statusCode).to.eq(302)
          expect(res.headers["set-cookie"]).to.deep.eq(["foo=bar; Path=/"])
          expect(res.headers["location"]).to.eq("/css/")

      [301, 302, 303, 307, 308].forEach (code) =>
        it "handles direct for status code: #{code}", ->
          @setup("http://auth.example.com")
          .then =>
            nock(@server._remoteOrigin)
            .get("/login")
            .reply(code, undefined, {
              Location: "http://app.example.com/users/1"
            })

            @rp({
              url: "http://auth.example.com/login"
              headers: {
                "Cookie": "__cypress.initial=true"
              }
            })
            .then (res) ->
              expect(res.statusCode).to.eq(code)
              expect(res.headers["set-cookie"]).to.include("__cypress.initial=true; Path=/")

    context "error handling", ->
      beforeEach ->
        @setup("http://www.github.com")

      it "status code 500", ->
        nock(@server._remoteOrigin)
        .get("/index.html")
        .reply(500)

        @rp({
          url: "http://www.github.com/index.html"
          headers: {
            "Cookie": "__cypress.initial=true"
          }
        })
        .then (res) ->
          expect(res.statusCode).to.eq(500)

      ## allow nock to throw here
      it "does not send back initial_500 content on error when initial is false"

      it "sends back initial_500 content", ->
        nock(@server._remoteOrigin)
        .get("/index.html")
        .reply(500, "FAIL WAIL")

        @rp({
          url: "http://www.github.com/index.html"
          headers: {
            "Cookie": "__cypress.initial=true"
          }
        })
        .then (res) =>
          expect(res.statusCode).to.eq(500)
          expect(res.body).to.include("<span data-cypress-visit-error></span>")
          expect(res.body).to.include("<a href=\"#{@server._remoteOrigin}/index.html\" target=\"_blank\">#{@server._remoteOrigin}/index.html</a>")
          expect(res.body).to.include("Did you forget to start your web server?")

      it "sends back 500 when file does not exist locally", ->
        @setup("<root>")
        .then =>
          @rp({
            url: "http://localhost:2020/foo/views/test/index.html"
            headers: {
              "Cookie": "__cypress.initial=true"
            }
          })
          .then (res) =>
            expect(res.statusCode).to.eq(500)
            expect(res.body).to.include("<span data-cypress-visit-error></span>")
            expect(res.body).to.include("file://")
            expect(res.body).to.include("This file could not be served from your file system.")

      it "sets x-cypress-error and x-cypress-stack headers when file does not exist", ->
        @setup("<root>")
        .then =>
          @rp({
            url: "http://localhost:2020/foo/views/test/index.html"
            headers: {
              "Cookie": "__cypress.initial=true"
            }
          })
          .then (res) =>
            expect(res.statusCode).to.eq(500)
            expect(res.headers["x-cypress-error"]).to.match(/ENOENT: no such file or directory/)
            expect(res.headers["x-cypress-stack"]).to.match(/ENOENT: no such file or directory/)

      it "does not set x-cypress-error or x-cypress-stack when error is null", ->
        nock(@server._remoteOrigin)
        .get("/index.html")
        .reply(500, "FAIL WAIL")

        @rp({
          url: "http://www.github.com/index.html"
          headers: {
            "Cookie": "__cypress.initial=true"
          }
        })
        .then (res) =>
          expect(res.statusCode).to.eq(500)
          expect(res.headers).not.to.have.property("x-cypress-error")
          expect(res.headers).not.to.have.property("x-cypress-stack")

      it "does not send back initial 500 content on 4xx errors", ->
        nock(@server._remoteOrigin)
        .get("/index.html")
        .reply(404, "404 not found", {
          "Content-Type": "html/html"
        })

        @rp({
          url: "http://www.github.com/index.html"
          headers: {
            "Cookie": "__cypress.initial=true"
          }
        })
        .then (res) =>
          expect(res.statusCode).to.eq(404)
          expect(res.body).to.eq("404 not found")

    context "headers", ->
      beforeEach ->
        @setup("http://localhost:8080")

      describe "when unload is true", ->
        it "automatically redirects back to clientRoute", ->
          @rp({
            url: "http://localhost:8080/_"
            headers: {
              "Cookie": "__cypress.unload=true; __cypress.initial=true"
            }
          })
          .then (res) =>
            expect(res.statusCode).to.eq(302)
            expect(res.headers["location"]).to.eq("/__/")

      describe "when initial is true", ->
        it "sets back to false", ->
          nock(@server._remoteOrigin)
          .get("/app.html")
          .reply 200, "OK", {
            "Content-Type" : "text/html"
          }

          @rp({
            url: "http://localhost:8080/app.html"
            headers: {
              "Cookie": "__cypress.initial=true"
            }
          })
          .then (res) =>
            expect(res.statusCode).to.eq(200)
            expect(res.headers["set-cookie"]).to.match(/initial=false/)

      describe "when initial is false", ->
        it "does not reset initial or remoteHost", ->
          nock(@server._remoteOrigin)
          .get("/app.html")
          .reply 200, "OK", {
            "Content-Type" : "text/html"
          }

          @rp({
            url: "http://localhost:8080/app.html"
            headers: {
              "Cookie": "__cypress.initial=false"
            }
          })
          .then (res) ->
            expect(res.statusCode).to.eq(200)

            ## there shouldnt be any cookies set here by us
            expect(res.headers["set-cookie"]).not.to.exist

      it "sends with Transfer-Encoding: chunked without Content-Length", ->
        nock(@server._remoteOrigin)
        .get("/login")
        .reply 200, new Buffer("foo"), {
          "Content-Type": "text/html"
        }

        @rp({
          url: "http://localhost:8080/login"
          headers: {
            "Cookie": "__cypress.initial=true"
          }
        })
        .then (res) ->
          expect(res.statusCode).to.eq(200)
          expect(res.body).to.eq("foo")
          expect(res.headers["transfer-encoding"]).to.eq("chunked")
          expect(res.headers).not.to.have.property("content-length")

      it "does not have Content-Length", ->
        nock(@server._remoteOrigin)
        .get("/login")
        .reply 200, "foo", {
          "Content-Type": "text/html"
          "Content-Length": 123
        }

        @rp({
          url: "http://localhost:8080/login"
          headers: {
            "Cookie": "__cypress.initial=true"
          }
        })
        .then (res) ->
          expect(res.statusCode).to.eq(200)
          expect(res.body).to.eq("foo")
          expect(res.headers["transfer-encoding"]).to.eq("chunked")
          expect(res.headers).not.to.have.property("content-length")

      it "forwards cookies from incoming responses", ->
        nock(@server._remoteOrigin)
        .get("/login")
        .reply 200, "OK", {
          "set-cookie" : "userId=123"
        }

        @rp({
          url: "http://localhost:8080/login"
          headers: {
            "Cookie": "__cypress.initial=false"
          }
        })
        .then (res) ->
          expect(res.statusCode).to.eq(200)
          expect(res.headers["set-cookie"]).to.match(/userId=123/)

      it "appends to previous cookies from incoming responses", ->
        nock(@server._remoteOrigin)
        .get("/login")
        .reply 200, "OK", {
          "set-cookie" : "userId=123; Path=/"
        }

        @rp({
          url: "http://localhost:8080/login"
          headers: {
            "Cookie": "__cypress.initial=true"
          }
        })
        .then (res) ->
          expect(res.statusCode).to.eq(200)

          expect(res.headers["set-cookie"]).to.deep.eq [
            "userId=123; Path=/"
            "__cypress.initial=false; Path=/"
          ]

      it "appends cookies on redirects", ->
        nock(@server._remoteOrigin)
        .get("/login")
        .reply 302, undefined, {
          "location": "/dashboard"
          "set-cookie" : "userId=123; Path=/"
        }

        @rp({
          url: "http://localhost:8080/login"
          headers: {
            "Cookie": "__cypress.initial=true"
          }
        })
        .then (res) ->
          expect(res.statusCode).to.eq(302)

          expect(res.headers["location"]).to.eq("/dashboard")
          expect(res.headers["set-cookie"]).to.deep.eq [
            "userId=123; Path=/"
            "__cypress.initial=true; Path=/"
          ]

      it "forwards other headers from incoming responses", ->
        nock(@server._remoteOrigin)
        .get("/auth")
        .reply 200, "OK", {
          "x-token" : "abc-123"
        }

        @rp({
          url: "http://localhost:8080/auth"
          headers: {
            "Cookie": "__cypress.initial=true"
          }
        })
        .then (res) ->
          expect(res.statusCode).to.eq(200)

          expect(res.headers["x-token"]).to.eq("abc-123")

      it "forwards headers to outgoing requests", ->
        nock(@server._remoteOrigin)
        .get("/bar")
        .matchHeader("x-custom", "value")
        .reply 200, "hello from bar!", {
          "Content-Type": "text/html"
        }

        @rp({
          url: "http://localhost:8080/bar"
          headers: {
            "Cookie": "__cypress.initial=true"
            "x-custom": "value"
          }
        })
        .then (res) ->
          expect(res.statusCode).to.eq(200)
          expect(res.body).to.eq("hello from bar!")

      it "omits x-frame-options", ->
        nock(@server._remoteOrigin)
        .get("/bar")
        .reply 200, "OK", {
          "Content-Type": "text/html"
          "x-frame-options": "SAMEORIGIN"
        }

        @rp("http://localhost:8080/bar")
        .then (res) ->
          expect(res.statusCode).to.eq(200)
          expect(res.headers).not.to.have.property("x-frame-options")

      it "omits content-security-policy", ->
        nock(@server._remoteOrigin)
        .get("/bar")
        .reply 200, "OK", {
          "Content-Type": "text/html"
          "content-security-policy": "foobar;"
        }

        @rp({
          url: "http://localhost:8080/bar"
          headers: {
            "Cookie": "__cypress.initial=false"
          }
        })
        .then (res) ->
          expect(res.statusCode).to.eq(200)
          expect(res.headers).not.to.have.property("content-security-policy")

      it "does not modify host origin header", ->
        @setup("http://foobar.com")
        .then =>
          nock(@server._remoteOrigin)
          .get("/css")
          .matchHeader("host", "foobar.com")
          .reply(200)

          @rp({
            url: "http://foobar.com/css"
            headers: {
              "Cookie": "__cypress.initial=false"
            }
          })
          .then (res) ->
            expect(res.statusCode).to.eq(200)

      it "does not cache when initial response", ->
        nock(@server._remoteOrigin)
        .get("/")
        .reply 200, "hello from bar!", {
          "Content-Type": "text/html"
        }

        @rp({
          url: "http://localhost:8080/"
          headers: {
            "Cookie": "__cypress.initial=true"
          }
        })
        .then (res) ->
          expect(res.statusCode).to.eq(200)
          expect(res.headers["cache-control"]).to.eq("no-cache, no-store, must-revalidate")

      it "does cache when not initial response", ->
        nock(@server._remoteOrigin)
        .get("/")
        .reply 200, "hello from bar!", {
          "Content-Type": "text/html"
          "Cache-Control": "max-age=86400"
        }

        @rp({
          url: "http://localhost:8080/"
          headers: {
            "Cookie": "__cypress.initial=false"
          }
        })
        .then (res) ->
          expect(res.statusCode).to.eq(200)
          expect(res.headers["cache-control"]).to.eq("max-age=86400")

      it "forwards origin header", ->
        nock(@server._remoteOrigin)
        .get("/foo")
        .matchHeader("host",   "localhost:8080")
        .matchHeader("origin", "http://localhost:8080")
        .reply(200, "OK", {
          "Content-Type": "text/html"
        })

        @rp({
          url: "http://localhost:8080/foo"
          headers: {
            "Cookie": "__cypress.initial=false"
            "Origin": "http://localhost:8080"
          }
        })
        .then (res) ->
          expect(res.statusCode).to.eq(200)
          expect(res.body).to.eq("OK")

    context "content injection", ->
      beforeEach ->
        @setup("http://www.google.com")

      it "injects sinon content into head", ->
        contents = removeWhitespace Fixtures.get("server/expected_sinon_inject.html")

        nock(@server._remoteOrigin)
        .get("/bar")
        .reply 200, "<html> <head> <title>foo</title> </head> <body>hello from bar!</body> </html>", {
          "Content-Type": "text/html"
        }

        @rp({
          url: "http://www.google.com/bar"
          headers: {
            "Cookie": "__cypress.initial=true"
          }
        })
        .then (res) ->
          expect(res.statusCode).to.eq(200)

          body = removeWhitespace(res.body)
          expect(body).to.eq contents

      it "injects when head has attributes", ->
        contents = removeWhitespace Fixtures.get("server/expected_head_inject.html")

        nock(@server._remoteOrigin)
        .get("/bar")
        .reply 200, "<html> <head prefix=\"og: foo\"> <meta name=\"foo\" content=\"bar\"> </head> <body>hello from bar!</body> </html>",
          "Content-Type": "text/html"

        @rp({
          url: "http://www.google.com/bar"
          headers: {
            "Cookie": "__cypress.initial=true"
          }
        })
        .then (res) ->
          expect(res.statusCode).to.eq(200)

          body = removeWhitespace(res.body)
          expect(body).to.eq contents

      it.skip "injects even when head tag is missing", ->
        contents = removeWhitespace Fixtures.get("server/expected_no_head_tag_inject.html")

        nock(@server._remoteOrigin)
          .get("/bar")
          .reply 200, "<html> <body>hello from bar!</body> </html>",
            "Content-Type": "text/html"

        supertest(@srv)
          .get("/bar")
          .set("Cookie", "__cypress.initial=true")
          .expect(200)
          .then (res) ->
            body = removeWhitespace(res.body)
            expect(body).to.eq contents

      it "injects sinon content after following redirect", ->
        contents = removeWhitespace Fixtures.get("server/expected_sinon_inject.html")

        nock(@server._remoteOrigin)
        .get("/bar")
        .reply 302, undefined, {
          ## redirect us to google.com!
          "Location": "http://www.google.com/foo"
        }

        nock(@server._remoteOrigin)
        .get("/foo")
        .reply 200, "<html> <head> <title>foo</title> </head> <body>hello from bar!</body> </html>", {
          "Content-Type": "text/html"
        }

        @rp({
          url: "http://www.google.com/bar"
          headers: {
            "Cookie": "__cypress.initial=true"
          }
        })
        .then (res) =>
          expect(res.statusCode).to.eq(302)
          expect(res.headers["location"]).to.eq("http://www.google.com/foo")
          expect(res.headers["set-cookie"]).to.match(/initial=true/)

          @rp(res.headers["location"])
          .then (res) ->
            expect(res.statusCode).to.eq(200)
            expect(res.headers["set-cookie"]).to.match(/initial=false/)

            body = removeWhitespace(res.body)
            expect(body).to.eq contents

      it "does not inject when not initial", ->
        nock(@server._remoteOrigin)
        .get("/bar")
        .reply 200, "<html><head></head></html>", {
          "Content-Type": "text/html"
        }

        @rp({
          url: "http://www.google.com/bar"
          headers: {
            "Cookie": "__cypress.initial=false"
          }
        })
        .then (res) ->
          expect(res.statusCode).to.eq(200)
          expect(res.body).to.eq("<html><head></head></html>")

    context "FQDN rewriting", ->
      beforeEach ->
        @setup("http://www.google.com")

      it "does not rewrite html when initial", ->
        nock(@server._remoteOrigin)
        .get("/bar")
        .reply 200, "<html><body><a href='http://www.google.com'>google</a></body></html>",
          "Content-Type": "text/html"

        @rp({
          url: "http://www.google.com/bar"
          headers: {
            "Cookie": "__cypress.initial=true"
          }
        })
        .then (res) ->
          expect(res.statusCode).to.eq(200)

          body = res.body
          expect(body).to.eq "<html><body><a href='http://www.google.com'>google</a></body></html>"

      it "does not rewrite html when not initial", ->
        nock(@server._remoteOrigin)
        .get("/bar")
        .reply 200, "<html><body><a href='http://www.google.com'>google</a></body></html>",
          "Content-Type": "text/html"

        @rp({
          url: "http://www.google.com/bar"
          headers: {
            "Cookie": "__cypress.initial=false"
          }
        })
        .then (res) ->
          expect(res.statusCode).to.eq(200)

          body = res.body
          expect(body).to.eq "<html><body><a href='http://www.google.com'>google</a></body></html>"

      it "rewrites <svg> without hanging", ->
        ## if this test finishes without timing out we know its all good
        contents = removeWhitespace Fixtures.get("server/err_response.html")

        nock(@server._remoteOrigin)
        .get("/bar")
        .reply 200, contents,
          "Content-Type": "text/html; charset=utf-8"

        @rp({
          url: "http://www.google.com/bar"
          headers: {
            "Cookie": "__cypress.initial=true"
          }
        })
        .then (res) ->
          expect(res.statusCode).to.eq(200)

    context "<root> file serving", ->
      beforeEach ->
        Fixtures.scaffold()

        @setup("/index.html", {
          projectRoot: Fixtures.projectPath("no-server")
          config: {
            fileServerFolder: "dev"
            integrationFolder: "my-tests"
          }
        })
        .then =>
          @rp({
            url: "http://localhost:2020/index.html"
            headers: {
              "Cookie": "__cypress.initial=true"
            }
          })
          .then (res) ->
            expect(res.statusCode).to.eq(200)
            expect(res.body).to.match(/index.html content/)
            expect(res.body).to.match(/sinon.js/)

            expect(res.headers["set-cookie"]).to.match(/initial=false/)
            expect(res.headers["etag"]).to.be.undefined
            expect(res.headers["last-modified"]).to.be.undefined

      afterEach ->
        Fixtures.remove("no-server")

      it "sets etag", ->
        @rp("http://localhost:2020/assets/app.css")
        .then (res) ->
          expect(res.statusCode).to.eq(200)
          expect(res.body).to.eq("html { color: black; }")
          expect(res.headers["etag"]).to.be.a("string")

      it "sets last-modified", ->
        @rp("http://localhost:2020/assets/app.css")
        .then (res) =>
          expect(res.headers["last-modified"]).to.be.a("string")

      it "streams from file system", ->
        @rp("http://localhost:2020/assets/app.css")
        .then (res) ->
          expect(res.statusCode).to.eq(200)
          expect(res.body).to.eq("html { color: black; }")

      it "sets content-type", ->
        @rp("http://localhost:2020/assets/app.css")
        .then (res) ->
          expect(res.statusCode).to.eq(200)
          expect(res.headers["content-type"]).to.match(/text\/css/)

      it "disregards anything past the pathname", ->
        @rp("http://localhost:2020/assets/app.css?foo=bar#hash")
        .then (res) ->
          expect(res.statusCode).to.eq(200)
          expect(res.body).to.eq("html { color: black; }")

      it "can serve files with spaces in the path", ->
        @rp("http://localhost:2020/a space/foo.txt")
        .then (res) ->
          expect(res.statusCode).to.eq(200)
          expect(res.body).to.eq("foo")

    context "http file serving", ->
      beforeEach ->
        @setup("http://getbootstrap.com")
        .then =>
          nock(@server._remoteOrigin)
          .get("/components")
          .reply 200, "content page", {
            "Content-Type": "text/html"
          }

          @rp("http://getbootstrap.com/components")
          .then (res) ->
            expect(res.statusCode).to.eq(200)

      it "proxies http requests", ->
        nock(@server._remoteOrigin)
        .get("/assets/css/application.css")
        .reply 200, "html { color: #333 }", {
          "Content-Type": "text/css"
        }

        @rp("http://getbootstrap.com/assets/css/application.css")
        .then (res) ->
          expect(res.statusCode).to.eq(200)
          expect(res.body).to.eq("html { color: #333 }")

    context "when session is already set", ->
      beforeEach ->
        @setup("http://getbootstrap.com")
        .then =>
          ## make an initial request to set the
          ## session proxy!
          nock(@server._remoteOrigin)
          .get("/css")
          .reply 200, "css content page", {
            "Content-Type": "text/html"
          }

          @rp("http://getbootstrap.com/css")
          .then (res) ->
            expect(res.statusCode).to.eq(200)

      it "proxies to the remote session", ->
        nock(@server._remoteOrigin)
        .get("/assets/css/application.css")
        .reply 200, "html { color: #333 }", {
          "Content-Type": "text/css"
        }

        @rp("http://getbootstrap.com/assets/css/application.css")
        .then (res) ->
          expect(res.statusCode).to.eq(200)
          expect(res.body).to.eq("html { color: #333 }")

    context "localhost", ->
      beforeEach ->
        @setup("http://localhost:6565")

      it "makes requests to ipv6 when ipv4 fails", (done) ->
        dns.lookup "localhost", {all: true}, (err, addresses) =>
          return done(err) if err

          ## if we dont have multiple addresses aka ipv6 then
          ## just skip this test
          return done() if not _.find(addresses, {family: 6})

          ## create a server that is only bound to ipv6
          ## and ensure that it is found by localhost dns lookup
          server = http.createServer (req, res) ->
            res.writeHead(200)
            res.end()

          ## start the server listening on ipv6 only
          server.listen 6565, "::1", =>

            @rp("http://localhost:6565/#/foo")
            .then (res) ->
              expect(res.statusCode).to.eq(200)

              server.close -> done()

      it "handles 204 no content status codes", ->
        nock("http://localhost:6565")
        .get("/user/rooms")
        .reply(204, "")

        @rp("http://localhost:6565/user/rooms")
        .then (res) ->
          expect(res.statusCode).to.eq(204)

          expect(res.body).to.eq("")

      # it "handles protocol-less proxies", ->
      #   nock("http://www.cdnjs.com")
      #     .get("backbone.js")
      #     .reply 200, "var foo;", {
      #       "Content-Type" : "text/javascript"
      #     }

      #   supertest(@srv)
      #   .get("/www.cdnjs.com/backbone.js")
      #   .expect(200)

  context "POST *", ->
    beforeEach ->
      @setup("http://localhost:8000")

    it "processes POST + redirect on remote proxy", ->
      nock(@server._remoteOrigin)
      .post("/login", {
        username: "brian@cypress.io"
        password: "foobar"
      })
      .reply 302, undefined, {
        "Location": "/dashboard"
      }

      @rp({
        method: "POST"
        url: "http://localhost:8000/login"
        form: {
          username: "brian@cypress.io"
          password: "foobar"
        }
        headers: {
          "Cookie": "__cypress.initial=false"
        }
      })
      .then (res) ->
        expect(res.statusCode).to.eq(302)
        expect(res.headers["location"]).to.match(/dashboard/)

    ## this happens on a real form submit because beforeunload fires
    ## and initial=true gets set
    it "processes POST + redirect on remote initial", ->
      nock(@server._remoteOrigin)
      .post("/login", {
        username: "brian@cypress.io"
        password: "foobar"
      })
      .reply 302, undefined, {
        "Location": "/dashboard"
      }

      @rp({
        method: "POST"
        url: "http://localhost:8000/login"
        form: {
          username: "brian@cypress.io"
          password: "foobar"
        }
        headers: {
          "Cookie": "__cypress.initial=true"
        }
      })
      .then (res) ->
        expect(res.statusCode).to.eq(302)
        expect(res.headers["location"]).to.match(/dashboard/)
        expect(res.headers["set-cookie"]).to.match(/initial=true/)

    it "does not fail on a big cookie", ->
      nock(@server._remoteOrigin)
      .post("/login")
      .reply(200)

      @rp({
        method: "POST"
        url: "http://localhost:8000/login"
        json: true
        body: {
          "query":{"bool":{"must":[{"filtered":{"filter":{"term":{"brand_id":3}}}},{"filtered":{"filter":{"term":{"is_live":true}}}},{"filtered":{"filter":{"bool":{"should":[{"term":{"subcategory_id":25}},{"term":{"subcategory_id":21}}]}}}}]}},"aggs":{"colors.raw3":{"filter":{},"aggs":{"colors.raw":{"terms":{"field":"colors.raw","size":50}},"colors.raw_count":{"cardinality":{"field":"colors.raw"}}}},"patterns.raw4":{"filter":{},"aggs":{"patterns.raw":{"terms":{"field":"patterns.raw","size":50}},"patterns.raw_count":{"cardinality":{"field":"patterns.raw"}}}},"custom_filters_a.raw5":{"filter":{},"aggs":{"custom_filters_a.raw":{"terms":{"field":"custom_filters_a.raw","size":50}},"custom_filters_a.raw_count":{"cardinality":{"field":"custom_filters_a.raw"}}}},"custom_filters_b.raw6":{"filter":{},"aggs":{"custom_filters_b.raw":{"terms":{"field":"custom_filters_b.raw","size":50}},"custom_filters_b.raw_count":{"cardinality":{"field":"custom_filters_b.raw"}}}}},"size":100
        }
        headers: {
          "Cookie": "_treebook_session=MmxpQUFjak1mZXN1L21FSnY2dzhJaWFPa0kxaXR2MFVMMTFKQnhFMTY0ZGhVZDJLV3BPUm9xT3BWREVDOFExTFBSaDEzY2htQTVVZ0dpZjg0VmF1SmRINlVSZ2ZFeFpzd0s3Yk4wakRxQS9TdW11N3ZURnIvbHAvQ2NTVjZWY0VqdFNQZTFHV09xclZnM0lDNE1JUzZzN3BWamF0dXRSM09uRFZZeWMwd01ESkdWUzY2MFE2QkY0cStIQnBwNGk0V3hhWkNVd0QwamtMeDJheWxxb04wZVkwRzJmdmVLZXJsR3M5UFAyK0Y3ST0tLTBFWmJwWktQaThrWnN6dUZVaVBGckE9PQ%3D%3D--a07f8cd3fc4db9a0c52676e274e71546a9f047fb; _my-site_session=NVp4akFGelljaFZJR3A4US9ES1ZBcTZ4K2ZqNklkUzNKZUVGU3RuQk1HSGZxenU1Z2VDOHBvTmdwL0x3c0E0TGEvTmZDWVR5Y205ZkVOZWwrYkdaWEV2V3k0T1h0elN1NjlsSWo1dFZqVG9nNy9MNWp6enoyZmdYSzYwb3d4WVlvMG9qVXlOTnNNSm1VYlpSSWc3bkFnPT0tLWhQcnVqQ0NQMGF6dVE0SCtRQk1sdmc9PQ%3D%3D--2d25be12c8415195314fe3990cad281c14022d9d; _first_app_session=ajBJcFpRa2dSR29MaTd5UUFnTU45dVZzd2tKeUY2enpuR1cyNFB2bVRCQ201RTh5bXAvaTdlN2NuRm1WeEJOZlkyTWtIRXhpZm1HTlZMM0hPeHVzWUkvQWNhUmNUcUNRRzlDbW8yMlA4SjFZSjhYQ1I4V0FNU3k2Um1mOHlQNU94SkdrT1ZmZS9PZHB6WDVGN0s4cGNnPT0tLTA0aE5hQStvbXQ5T1VXN0UrT3MxN0E9PQ%3D%3D--1daec80639465389f0e5437193e633eeb7bbfca9; _pet_store_session=N055S0M0azJlUlFJWGdDN01MQ3Z4aXFCWHNFU2ttZUp0SDJyL3BPeTVOdzBYWGROb1F1UWx2eG80ZjlobDF2QWJ4Rk5uVFliSWtMSEltZ2RUVDNZUVFLd2VYS3JTQldRbkNnMVdReVY0V1FyWjBNdTVjSk9SQUJNZ0JmMitEcG9JQnh0WVErY2lZaWo4WGJFeXpKUElBPT0tLUZDL2k3bUlKQUl4aGV3ZGEvQXRCaUE9PQ%3D%3D--a658fa7995dec5c7ec3e041d5dc5f52e4f7be0ee; _adventures_session=MDZDeDBDQmRJRFdpYzk5SWFEa0txd0xBVmQyei9xTUhQZ3VlZjNRcUY2c0VsWkZaNUo2SktlNGRvcFNrdDlqL0wzRnA4eVdpMTdMUjJlcHJuMkVWU05SdmNRa29QQU5HWlhxajRZcWNSY1lqR1RDZjhsQ3loUzMvd1M5V3ZCck5iMHRkQXgzcFAwRlBOMFFja2dURDFBPT0tLWMyMHZvcnV6OUIvS0tkeFFpTVA5Qnc9PQ%3D%3D--04a940aa32a208e9bfb6b422481e658f57411132; _classroom_session=NFRSY05TaHZZdkVMYkRZdXh5djQxSmxYY2xIaHJDamI3bGJuRjRxbDZCcWxCMVRxOVpkdWV2MnQ0ajBBNDdOb0ZtTUZPUkFLNmJ0SHFVUlJCZ3FUSjBvSUkxTzZpL1h6ZWhsVlJ6Z2xGRjhWamlVSHJ3NG1vZ3IxSC9PaUxkNVA0Q2x6ZDRTaXJxcGlvc0tsazdkRHFBPT0tLTZ1Z0hxcU16cmZoRTR1VHBqN3RkbXc9PQ%3D%3D--cea92642cc4ec52a81ad6892db90e0e8b8236069; _boo_scaffold_session=am5oQVhMN2ZQQlJBb2VUdDNtdUVic0NMeFlhWVJOa0Y5SEhERjdpUmd2aVZicnY0Z1VsL0hTWVNudTF0dm1SQWNKZHhzZmpJQi9FK1JZVXZwU3Q2RHNObmFWcVg5T0thYmUrY0k2YTJaQjMzUVp3MlRNenk3a2JxczdWZmF6MUxEaW1EejlxeWpUNjFack4rM3N1bm5yZlFKT3BTYnIvTTNNaG5haXZrMEFZWUp2cHBRQnNXbldLUkRZZlBuRDlWdWRldTJqYmh6K0lWWGRyVGpOUERtbFBQUFVHS1pOR3RtMmRuYUxLbjUvYXQra3UwcUxkK3BHRzFRR2RqMWVGay0tQU9DdlFMNEluVVJPTUNlbDh3L1Y0Zz09--c3e2745720ea2080dadaac45223d36ed15fd7fb4; _db_explore_session=RW5NUDlSaG5SVFF4Zms4YmRwQmhZaitrckhRVXN0VzlKS3E3M3Fxa0xwQmZGcDY1amlVOG5DRnpPQ3hLSVBoUFZ5b3lKWGd2Z0JZWnptMEREcU1DUE04SkRMN1RUbVUvUDFaTkNFcUpqQkZ0NmxjTkhrZHZlM1pibmIyTGQxZ3UzNVpvTUlDSnNhcUxBcHRJaVJqdENRPT0tLTBXWVhqK3lwcTVONzVLRVhnZldmQkE9PQ%3D%3D--10c607bc41831a8b4e80689d051a5cfc19872cc1; _furniture_store_session=cm5lTW9XR0ptc2lCSVJNY0c3dW1oVFlJdG9OaGh1OENhdjgyMW5Heis0RlB3ZkNPR2ZZUmdiV1VlbGY3NmdmdHU0cERBZGtpWGFUeHo5cHM4K1lKa053cEhrV2VaR3Q5RVYzZms0VVh2aFBrd2N6U3hzeWhZTEhnVG1qYldxNFZOemVTMGRkQmZQSEFHWEJZZWNQWS9BPT0tLWk1R0d0SW1pZVEyckRGK2R1Vzh4M0E9PQ%3D%3D--99c9ed2f5a43af5bc018d930b6210b50bf973a79; _travel_session=VEcxVlB4NTg0SGNHdjdOekZndW5Jc1FJY2VJd3NTaDhVVk4vNnVuekpWUVE2ekVhK25YVWVUemhOUnl2S3pVWTc3U0trTTI2cUVNakwyd254M3RMT0J2L0dheTdRUVpGY1FRd0FTT3pSaGpsK3kreVJxNVdMbWFsY3pWSVdMUU5mRzRzQnIzRzFNMS8zQThZQStLTE9nPT0tLVNMK2hsYjVpRmZNMngwUFI1QU0zemc9PQ%3D%3D--19113054b718f1b9c733427c9a3e110b60187f4f; _doctors_office_session=RGxTSWhxVm45am0rSGZVb25jRnBVdVRvcHIxbTR3dVZWdjYvYklGY3BVa2FnYm5sRXlNUlp2TmN2Q3R3NndxWnFFdStPT2ZieTVKaE1SMUpFM0ZUaFhUb3ZhbkxDbDlrZk9lUVh5dlRCY0hhQ1NVNUVKSjhJSnhyTkFkWi9FUm1UZis1VEhVb2tXQW9Qb2MrQU5IMHNRPT0tLUMxdlpYMEVKV081L3QveFBHMS9scWc9PQ%3D%3D--7a4196ea6b5194f412be549a0f30925ec6bd118f; _recipe_app_session=OE1saTRQZ1pRQnNrdHNCNllyNld3cnVTcnhqUjh0Q2NZaSt3eWlLbjljUWxMdk5seW9SVnQwcmZ4VVBhdWRDUE5qM1hWSi9QaW9adnVFalJ6VjJFVFFhWm1LZFB1ZXlzRzR1UFpDSks0V01pdWFuWk04bExMeDdvYWFZRU9OQm5qQ2ZKcXRLYUdiZmwvWTYwUCs4bnJBPT0tLVdtYkh4cmFJeHQrZXdoazFGSUo2aGc9PQ%3D%3D--1649c7bd76e8944a0911d9e6a59d5a82aa1a0559; _ajax-sample_session=ZDM2NU8xZTRocmxFUlR5ZjZhMGxUSkgzdmFOcVVrQ1ZUN1ZNMFliRGNuRFQ2SkNvV1pVdUlLRWVoY2dodWxQRjNiek84Y0dhdk44dkN6Sy9naDRsQjFRY2FVMXYzcXc3TkVzY28wMnp4OFdiWnBFMFEvNUltK1ZYUUd2THRMblpLVmJHOFIvMEVQaWpMV2dqamI1ZFBnPT0tLTJ4RURLbjVEYkZaSGpvdDk1RU9sNEE9PQ%3D%3D--f13942ae013f1252c609762922b21b8a233b36ed; _stripe_test_session=RnRoMngvN0IwVjBENElrY0w1eStwOGYxdDgxKzNBbStYaHErMkxRQk9xUGFMenRqU3h3UFVNSGNoKzNWSXZJMVZHMXYxcUoyeEpBMVRQVk9CQktOampnaFdYdUJzYTFjSTJJYlI5SkpzTVdPSVJTNU5GaGR2UVJqa3NNaW1UM1l2N2YxUWVKeEtzOUtneldlVjdNcm1BPT0tLWEyaVVValdCSlJhcmRJUmNXVGNqR3c9PQ%3D%3D--66f51d7d80652f09a3d2c56f94a8bd6380d4972b; _wunderground_session=SFViSXNZeVFMYkp0MXNOWkZiSW5BMG94QzlqOFBIZnBSOGY2S3B4RkIybzFZdFBQeUlZTlAwMjVNRWJqckRRc2R6V1pweWZhdmpqcTgrNWliM3Izbk4xaWo4d05Tc1YvMyt4L2tuNTlIVjlUZUpTZEwxcE0xUXRTTjAwQjI3eVpSM2c4MlRnY21jUEpIcGo4SjNnY0pRPT0tLTc3TlMrZjFJT1U2S1cySm9DN0RDNGc9PQ%3D%3D--accf1fa6ea2a345286abe82acd0e882d9f4f2c40; _ecommerce_app_session=S1JlZ3BYTDZraDdZU3RZUmpCMHR2aTRGaUpvL1BJN0p6MjRqM0krbXplRFdjemhOMnQ0ckp1ZERzTUp2eWQ5Zit2bEVCOGZLRU9pOHJCRHp1Z0Z1UUZtRlVEVnBhaFBielBjckNMVmlXR0dxS1ZabjNKUFdBcVBUR1JSUlUxYWFSemNNem50TzFxam9aU1BTRXpvQkNrWHpMMVdvUEM2MjdWbHh3NVdYU2QxM1ZwMmFWM3RZdjVlSWFnd1o5OWxtb1lMenJiVStKUnRRcHEzdHlSTGUvdDlCcnFXWDF5TTBmdXFPN0VsUHJxVk50dTREeHkzZG9PdERZV2l6WXJIOEpyVnRjU0FVOW9XeWpldzdZVFBXM0xFTktjQWFMbXpuWHlLay9pK0ZhSVZ6dUVsVXJleDYwR090QjdmaTIyb0E5ODh6cWVHaTE2SHFCZ2JrcWFaMmtWTlM0K0lVejNUZVZkQThGVTN4N3VBPS0ta1E2clFzb1VRQS91WEFOYjl2NGdJUT09--c47816c90bd08c466f3f8f60f4db07eb40807b08; _Top5_session=dndqMXRCdFVxbERXWCs4UStiQ1gwc0daWE9aOW1wRndWTHVjSk1kNXR1T2xoOUNwbk1ndGR0T1lqZXBkSUVuN2VPRU05RnNxcGx1aUg2RjJya1dWaUNTekZ4RzZCb0VvdEFNYmhaUHNjZXhmWDFWM3EzK0lVUm4yazhoaXZLZlpxSldqUC9GN1NMNm54NHpyRUpTK0tBPT0tLW5QQldSb2VVVWJ2V2syRDhXVUs1TlE9PQ%3D%3D--3f5773b8063cfd8dc61e917501485c86e625a4a6; _recruiting_session=cnlTQ2h6YWZKZFVPb1Q1cklSVngvK3hTK0M5ckhJUmhheE83QStTRThCeGg0dGpaNGJCMVRrUGFiQXphQm5Pb2FZbGNkV095bGdNNjlMUmRCTmhSa2duNzRzZEppc2JBT0VoSnZIVWlCMVJtWXZmZktJQWgvM3paM2ZKbmZCdWd4MGw0SHF3OGt6b0xJaXhXTzVGSGxaL2ZBNkNPZ0dGL0ZPMklkNXVKQXRTdFY4Y0J4bGx1eTZYWW9QQlpPZ2JsLS02b3NpWmZibGJGd3JhWEg0TUJzYUpBPT0%3D--722ac1ecda4ef81214e52effeef8fe14317c2bd3; _marta_near_me_session=N2MreUZINElveVZMN2NyNkUrUkduZVZBZHdHMVRCcHE1TE02ZXlKeGdJd21iYUlDeGl4aGkwWUNiODZPRVNPTTlGd1ZlRWlJZjZTUHVzZ25qWHdtaTg1NjBkR3hKQ2hjSWUvTElQY0t1azN3UmpJbXQ2T0xiTlpCOVphTkVxcjlrNVVGNXhNcTZaY3dVY0JEcmtUb0FkeWRVQVdtWm5sU3l4NG1tbWQ0Z2lSYXpNSUsvNGt1V0IwV2NQV1RjVEZ5NWpWUG0rQWR4N1FTSzlxcUFLRW1LOFVEY1VzaXd2K0x4OHJnRVV6OVdlNTI0ZFJGUytqbUNmMmI0SWJsVWpnRWhWTTNWRnUzYksvazNTK01Zd3drTWc9PS0tVWxaSG1FeGl5Z2JrcUxXUUl3aDhJUT09--80376da7d66242e7d73d7e1e598b115d22ec59d6; _sassy_session=MTBuOGpOaVlWbDc3NEl5U0t5U0o3OHk3N0VOc3FNbVdnU2xEajBqTGtaQm5sMStQT3E0bTlLZmpRYy9zY2xKOVgrK1hhcVhSc2UvalVWYm9jS2RlMlhMTCtOK1JETFZQRUtnTUxRSmlrOHFNU0l4SmxmSTRYcUIrSHJ4cEJBbUNZMXBCS3NBL3hoYmhJY2xOZlJyaW13PT0tLW5ZOTBjUS92MjJ3bXlNWlRwb2wvZFE9PQ%3D%3D--62667911aa0f694c2215d10622c4a2e6d4d41007; _gf-hackathon_session=Z0xBUTAreU1EM1h4NFluL3BsMUhicE9wa1BtUHdQRWRic2NpOWh3NjIyNnduamRsZGh4UDhFcW83MDhXenhhQ2ZsNloxKzZsa3RxQXcycVVtcUw4Tnh4UVRwTVVqUWJiOExtSnQwcHJFb1BnM3d4eTVjejgza3pPTFV2OEwwWTZ2UE04cmVwc3IvN21wRks3c0NWK1A1dEpYdmVsK1NlTGt4b2JKRkpSOE1Db2oxajE0aHQ4YS8wYXVLNDM0OTBkcXlQUzJUVFlUeFc5dUxuRzNtaVU4YWZUSVBKQVUwM1dkRmFJcUpiR0JlST0tLVJEMzZNUWpmU0hqcFEzbVAyLzlDVFE9PQ%3D%3D--7bd822b0ba783a644ba067a9bc664450c8d8c7bb; _Library_session=eXhPTWVQLzFWcVlzcCtIMVJReDdaSzBLZXFsa3NJeFpzb21RdUYyb1d1OHJGaWdhMmVxV1l2aDFkUHZ3dUhLalRFenN6QWpPVDFnSTFKQUJpaWE2MHJZOXVtaWVGSU95SnVQeE13ZmdoV0FMYlYvSDR1NVRQMld5NTgxYTRnbS9VekZlT1VuNkl0TVVwSDdWMDNsbFZ3PT0tLVpocjJmTjZBSDRueTEwc3VMWHZ5Rmc9PQ%3D%3D--7470bc2a23b85bab792f4a9d2ef7e75438503948; _fittery-project_session=NVdHZ2Y4c3h0VFJDQkQ1d1lmTFlNVnZyeml1RzVoN1NBMnh4OTFCYmdYQXQyS0oyT1M5R2R2WFRSNStmdEhWMVpmcWJJYTR2a1RwNnJ3b0RnTWpKZTE3amtPQVhYeERUVWdVbC9pbjF0U2g4T1FFQzJDb2pjZGFDZnhFUkJqOUtuN05jSG1WSVRaZm4wQUgxNjZNWllnPT0tLXhONHdmQkp6T2RvbEVyL09POU8xK2c9PQ%3D%3D--559898f1567aac047c39765abe134e9c9b5081c7; _rubix-3_0-rails_session=ckZBdUFhOCsvbjBxWGk4SGZyQkJkZGFvdG9ReG9wRVBkTVBrRzljN1d5WXMxbzBJakNXZ01KamdGZTdpbTNiTUZPNktObGppbzZndEdkaE84S1pRU3RubEpsMm1VTndiNlVmYk9oWmN6dHczc3RWWUMwUmg2a1JWN1gzK2lmR3Y0aHFBUEJjTU9qOFo3MlZmSkh1dkVRPT0tLVZuN3FJQnhuZER6UVlmaXUvWm5yaGc9PQ%3D%3D--beae7a3f4cd8c9179965f81f4da275b27c9fd20c; _mainmarket_session=OGNILytyTzFxR1RRd1I3dnJva2V1UWMrYzBBckRkRC9nWmxxWC9MdXhUcUMzV0QxbVFnUVAzdWpXU2l1VFByODNDdWRpUzYyVHVwVTFlamNIaGFiSk9kTkZWSy9kWHpqa0xneC9FeVNOZjNYbDhMVU1UT0dYOElua0NaMTV3dFRoV1RHaGRIS3dMcElTZ0p6K1QxYnVrWlNTRXJMenlkVUZ5aWtnWkpRSFZndEpFMHVNR3gxcFRGYVhKaGVUT3BvVEdKMGRRUmFERlQxUDYxbHRJc29OamZJWVM5UUJSeXZzMDVzaUxzN3JYcWswYXZHb0YxZTFuNlhxYlBleEs4ZFBvekkrOXFOYU9QeUcrUHowZ3FpUG0zaE5NamwvOUppZSs1VWV3NXczbi85M2pGWG5ENnlvd1lCcGc5bEpUTTZBeUkyM2Vyd09Vb0dqSjd6Q2x5Z1g4MllzZzV3TkU2ejZ4ek5lVmtGaHlIcGU5NWlXMlNLazc2N0JvUHorT2o0MURRQVFUbHZLMFBraHAxTWRYZGZmT2gzMUx0aDdkdDNESFdMV1hLTUJZQS9XS3RsSGc5U3FQSzJaUmRjdDBjMi0tQlgyVzJITjVPbURqN2gxK1d5dmdQZz09--121f584b91d060b407193488b5341fc4919bfa28; _blog_app_session=VU0xeHFmL29hRTdBTWl6WExCZ2JGbHFwL2s1Qnh0QXpBajlsU2ZseHpDdjl3TzhHZzl0NHhVSFVLUktqRTRxejlYTXVFMW9rRllZSTJ3NTlUcHZHYkdhaFFObG43bkN5VkgwbmdzRWY0c21ZT3RJM0lFcXpCMHh1YjRqakpMdFFPZzc4b1dXLzRsQWc5QXJPMTdZNmwzajBOeG5kRHduYzdObFZSUDNMakFHUXNmU3k3MFdCYkRncU94cE0zcEVyOEN6dER2aXYwUGo2Mm44NW1Ub29sSzJ2RUxGVmV4V05oM2JUUHVjV1hhRT0tLUM4YUM3MUpPeWtDSEYxMTU1aStyR3c9PQ%3D%3D--f30b07b16552349bfb6d11fbae3afd1cbac32bcf; _todo_list_session=eER5TjRjMWdEL0p4eVY1SHFlcUdCYzhVNldhRk5qclVEWTJCSVFjdkNZcXFvT053VXRpU1NKdG9qb3dFdGdpMUwwcmxXbmJIMXVrbDBxSFVjZTNXcHBIbDRkTXhGaTRmTm90YXZ4d2plSWtuWWlwZGdMSkVMRkliSS8wajhVejJ1MC83Q0h3d2NuaTdmMC9WT3o4NTVnPT0tLWtmUlh5SzFiQ2llZHk0am15d3dzeVE9PQ%3D%3D--5a16fdce0a2c0afe942f70c3203334df3a64d2e8; _tts-reddit_session=WkxWcERrRUJFNURkTGxvR3h5VHpPa2FhWXJhc0RrUElIOFVuT1ZhQ3FGSXhta0ZnVm1GNlVUdnJmOUxIOE9aTUhUcS9hMGY0bFl2K1dyUEYvTlpaNlNjTjV4OHBvWW1YdzM0SFozUkZKQTd5YktMeHI3dXRDV21hN3piaGhyalh6b1EzSExmb0Vod1FRYkhPeU1meFVGaUhPVVM5cllPV3dRT2dsQlM4Ty9vT3VRSkdmcTBsZlFhNXBrYU1CWWlMUE5FSmZDam5DRjlUOGdOMjlHOW9TdVVSYlR4MVlFdWZ2b0dzYTJFajhsMD0tLWY5a1o3U1krKzRUK3pBNmc0bEsyS2c9PQ%3D%3D--458a23790e533b457ebbb80e9dd5bdf76e0de77a; _tweeter_session=ZFpCZHR2dklyd0ozUzJ4ZDBCWjhGZVJ1bFlvNGo0bmdIdkltalN4aDNmY1RsbmlhczR4cThsa3JJUGlFZ0JxcHFiUSsxOU5LbDhVdmtsb2ttWndpUWVMcXYzNEpEbXRpZ3JyOERrQytxMmoxT0FZd1orNDdQOEFGNFFqWllyWmJIdHE1RFF5aVY5MndoOGVmOUpMZTZFbEdJTjk2QzhUQWZXOEJNOCtXbWphM2QwS2NxRkhOUFl6ZTIrMDd6RHFJd2QyTDJkVEh5SmhqSnZvVjZZUllFbU5vOExXQmFGM2ppV2JXSXBXRUo3ZVY5ZG5ycEo0dnRnb0kxeitUT1JNWmhTZnNIMDVvbjV4emxQUDF5b2x2Njk3djREZmNza0NudDB4ZW0yay8xaytYS2QrU0cySzJ0ZzEvUUdhcEZwanBoN3o0OWpsaHVmYTc0dUY3U0R6VDN3PT0tLUE0Zy9mS0VmcGp2bXNDSVJ4UGQ2ZkE9PQ%3D%3D--e1ca4a8f11b7d639e0235fec0644adf6e4576888; _angular_rails_reddit_session=RVQ2anNFSE1qK3VGYjFyMzdTTnRXc1ZDM25JNkNqT25OT1ZTK3RWUXptUWtwSHZwVE1vOE5tUWJML2NKUDZVemRYcThicUpYYzJxejJab3RPanRNR21BSTZVM2NBVFRZeE94OE9QVzVhUTFFdUJ6WmljbTN4eFVQV1VKMkVyY3RjYlE5dkRyZVArelFNSTV5UWdqVTJBPT0tLTN4dUlHaVZXcW1wZFNER1JyOFBxWlE9PQ%3D%3D--67046be80e6a383c4ecf3d47bfb8b5d58f5ed7d1; _fittery_session=b1FVdGtyVTN5Sy9MOWdHTEJzU0RxYjBEeERteC9tTTd3ekFOZE02eXV3VHNTM29XV0F4dVhUb1ppTzNmdHZKZGRUSWVpU0lYTm1vQ045TFFCWDhKZldQTFJ1cWpvTkFiZlBIQnVuL0I4SGhIODA0bFNwK1diOVJXVnZ0MzNaekovcEN3dDI2cHdjN3lUSnVlVzdoYjY5a04wYXJiQk41aTc5TGVleExwZkZzdExGTDJrejJtTktiL0p4K3FreENBYnlPTW1WWXFSbEZMWWtidFdzMldDSDVyaG1acEM0OVhxREVlMUg0S0xWcGV2Q0dxTzNaODZWWmhvWWFrNW55SEJ3ZmtEMjR1YlpYSk5uV1Flem4wUjV4U0hSSUtyQlF0QUcvQkc5TGtBWUl1UFRNNEhzLzgrVlg0RmxMcGw3QW42UDVmUjVqQ1hPd0V1K1M1aXFFb0NnPT0tLUw1K0dHZXh6b3pPMDBNT1YwZFEyVFE9PQ%3D%3D--527a62a03427f1ed30709c0a8a591cadb7a26cea; _ladies-of-tts_session=OHEwdWNLVFJyRU8yQTEyVjZyNUp6YzdyUjNJSlVreU15dktVRk1QNlEzQ0xRcUFTUUx3M0hlTEZlUnE5MkNadmZwaWtqTUp0SVRQaGFZcHZ1TDh3am5wZ3J3MnBMaHVFOG5oeDZXTDBRb2VHcmVKZS9ORUpHSmFmcHg0V0dWKzdESGRkZnpZUGVoM3lvQU02VVBaalBnPT0tLVRPbTNQSkY3VUczUUk5UnQ1OUtZNkE9PQ%3D%3D--f48ce24828b13200003ee27dcc8717925dcfc9ce; _three-good-things_session=RWZ0NS92QVN2dWoxWkpzVk1RNEN6UmlXMlFhSnYyc0pXd1l1Q2NzMGFQM1BmMkJlM1gzMG9LeTFKY3I0L2NoUzJwRk1PZnprQUx6U3duUStYYkFBT055WkVRVVIxdlVkalFUaVNBaEdqSW9EM1ZSMUR5d0pUbDgxcUJ5cnZ5cDY5YkFhUlJYTStzZ0JINENTbnFjK2tGU1IxZEg2TWlnUGtuUjlvRXozbnVrcFdEZFlOQWdTREFVTCtOTHRhUW1MZDFWMXVSSDZwdXNmQWlHRlk1Q3ZsWmJWbjMwb0NjRDhNQk90L0YyY1RRST0tLVY2ZnZRemluWWNkY2ZyNTJONEpWNmc9PQ%3D%3D--0e7bf64b6d71d668d845f98f35c1f94d239aefc3; _my_site_session=MFE2NWZydk1Fa05PRHpwbWdDNzl3TXJZZHFEa01pdEFSQUdsSWpzN0F0dGx6cklacFZzV2hsaTdITWpubU5PUDdYU1ZZWkZEOUpWb1pIbDUyeDVHR0ZiNDZHU0U4K2V4QnU0K2pRTmdpdWNlUHFvTnZMQ3g3MHBDSEhjV2VKOWRoTEVFUm9NRWdIUzZ1YjFIaE9aVVlnPT0tLWpjVUVuaHJyM0JoWm1GUit0WmFWL2c9PQ%3D%3D--d7711f08ae193bd0528e10198728887b9eedc426; _rails-starter-kit_session=NmRveUJiZ0RMTTlRR003L1RrUE5lem5oMmRjdG5xMmtZcDRlUTFWRjBXNmNPMkFvT1RqSFBPd1pBQVBHSHRLSmg3Qk53WXZ3Ykp6bkQvT2lqa2dyQU5ZYXlJcXBnaEdabzhTSEJteHl5K1lBNzU2R1BMNGx6WGpFa1dOTVpOUS9mZ09LZWJYZlQwMjhRL2xiWFBnVU9BPT0tLUthVEdXNDlQZDREQTd0MWVkU093SUE9PQ%3D%3D--41cea213452b8234f53415d44c98bf55997633be; step-1=60; step-2=140; step-3=0; step-4=13; step-5=30; step-6=26; step-7=26; step-8=0; current-step=9; step-9=0; sid=111; __cypress.initial=false; __cypress.remoteHost=http://localhost:8000; best_fit=14 1/2, 34-35, Traditional"
        }
      })
      .then (res) ->
        expect(res.statusCode).to.eq(200)

    it "hands back 201 status codes", ->
      nock(@server._remoteOrigin)
      .post("/companies/validate", {
        payload: {name: "Brian"}
      })
      .reply(201)

      @rp({
        method: "POST"
        url: "http://localhost:8000/companies/validate"
        json: true
        body: {
          payload: {name: "Brian"}
        }
        headers: {
          "Cookie": "__cypress.initial=false"
        }
      })
      .then (res) ->
        expect(res.statusCode).to.eq(201)
