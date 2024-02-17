module Main exposing (main)

import Browser
import Color
import Dict
import DocsChanges
import Element exposing (Element)
import Element.Background
import Element.Border
import Element.Font
import Element.Input
import Elm.Docs
import Elm.Pretty
import Elm.Syntax.Node
import Elm.Syntax.Type
import Elm.Syntax.TypeAlias
import Elm.Syntax.TypeAnnotation
import Elm.Type
import ElmSyntaxHighlight
import File exposing (File)
import File.Select
import Html exposing (Html)
import Html.Attributes
import Html.Events
import Http
import Json.Decode
import Pretty
import Task


type State
    = State
        { earlier : DocsJsonSourceState
        , later : DocsJsonSourceState
        , latestError : Maybe String
        }


type alias DocsJsonSourceState =
    { packageAuthor : String
    , packageName : String
    , versionMajor : String
    , versionMinor : String
    , versionPatch : String
    , docs : Maybe (List Elm.Docs.Module)
    }


type Event
    = DocsJsonSourceEvent { earlierOrLater : EarlierOrLater, event : DocsJsonSourceEvent }


type EarlierOrLater
    = Earlier
    | Later


type DocsJsonSourceEvent
    = PackageDocsJsonSourceEvent PackageDocsJsonSourceEvent
    | DocsRequested VersionedFullPackageName
    | DocsReceived (Result Http.Error (List Elm.Docs.Module))
    | FilesSelectEvent FilesSelectEvent


type PackageDocsJsonSourceEvent
    = PackageAuthorChanged String
    | PackageNameChanged String
    | VersionMajorChanged String
    | VersionMinorChanged String
    | VersionPatchChanged String


main : Program () State Event
main =
    Browser.document
        { init = \() -> ( initialState, Cmd.none )
        , update = \event state -> state |> reactTo event
        , view = ui
        , subscriptions = subscriptions
        }


initialState : State
initialState =
    State
        { earlier =
            { packageAuthor = "elm"
            , packageName = "http"
            , versionMajor = "1"
            , versionMinor = "0"
            , versionPatch = "0"
            , docs = Nothing
            }
        , later =
            { packageAuthor = "elm"
            , packageName = "http"
            , versionMajor = "2"
            , versionMinor = "0"
            , versionPatch = "0"
            , docs = Nothing
            }
        , latestError = Nothing
        }


subscriptions : State -> Sub Event
subscriptions =
    \_ ->
        Sub.none


reactTo : Event -> (State -> ( State, Cmd Event ))
reactTo event =
    case event of
        DocsJsonSourceEvent docsJsonSource ->
            case docsJsonSource.event of
                PackageDocsJsonSourceEvent packageDocsJsonSource ->
                    \(State state) ->
                        ( (case packageDocsJsonSource of
                            PackageAuthorChanged new ->
                                state
                                    |> earlierOrLaterFieldAlter docsJsonSource.earlierOrLater
                                        (\docsJsonSourceState -> { docsJsonSourceState | packageAuthor = new })

                            PackageNameChanged new ->
                                state
                                    |> earlierOrLaterFieldAlter docsJsonSource.earlierOrLater
                                        (\docsJsonSourceState -> { docsJsonSourceState | packageName = new })

                            VersionMajorChanged new ->
                                state
                                    |> earlierOrLaterFieldAlter docsJsonSource.earlierOrLater
                                        (\docsJsonSourceState -> { docsJsonSourceState | versionMajor = new })

                            VersionMinorChanged new ->
                                state
                                    |> earlierOrLaterFieldAlter docsJsonSource.earlierOrLater
                                        (\docsJsonSourceState -> { docsJsonSourceState | versionMinor = new })

                            VersionPatchChanged new ->
                                state
                                    |> earlierOrLaterFieldAlter docsJsonSource.earlierOrLater
                                        (\docsJsonSourceState -> { docsJsonSourceState | versionPatch = new })
                          )
                            |> State
                        , Cmd.none
                        )

                FilesSelectEvent (FilesDropped file) ->
                    \state ->
                        ( state
                        , file
                            |> File.toString
                            |> Task.perform
                                (\fileString ->
                                    DocsJsonSourceEvent
                                        { earlierOrLater = docsJsonSource.earlierOrLater
                                        , event =
                                            fileString
                                                |> Json.Decode.decodeString (Json.Decode.list Elm.Docs.decoder)
                                                |> Result.mapError (\error -> error |> Json.Decode.errorToString |> Http.BadBody)
                                                |> DocsReceived
                                        }
                                )
                        )

                FilesSelectEvent FilesSelectClicked ->
                    \state ->
                        ( state
                        , File.Select.file [ "application/json" ]
                            (\file ->
                                DocsJsonSourceEvent
                                    { earlierOrLater = docsJsonSource.earlierOrLater
                                    , event = FilesSelectEvent (FilesDropped file)
                                    }
                            )
                        )

                DocsRequested fullPackageName ->
                    \state ->
                        ( state
                        , fetchPackageDocs fullPackageName
                            |> Cmd.map
                                (\result ->
                                    DocsJsonSourceEvent
                                        { earlierOrLater = docsJsonSource.earlierOrLater
                                        , event = result |> DocsReceived
                                        }
                                )
                        )

                DocsReceived (Ok docsReceived) ->
                    \(State state) ->
                        ( state
                            |> earlierOrLaterFieldAlter docsJsonSource.earlierOrLater
                                (\docsJsonSourceState -> { docsJsonSourceState | docs = docsReceived |> Just })
                            |> State
                        , Cmd.none
                        )

                DocsReceived (Err httpError) ->
                    \(State state) ->
                        ( { state | latestError = httpError |> Debug.toString |> Just }
                            |> State
                        , Cmd.none
                        )


earlierOrLaterFieldAlter :
    EarlierOrLater
    -> (field -> field)
    -> ({ r | earlier : field, later : field } -> { r | earlier : field, later : field })
earlierOrLaterFieldAlter earlierOrLater alter =
    case earlierOrLater of
        Earlier ->
            \r -> { r | earlier = r.earlier |> alter }

        Later ->
            \r -> { r | later = r.later |> alter }


fetchPackageDocs : VersionedFullPackageName -> Cmd (Result Http.Error (List Elm.Docs.Module))
fetchPackageDocs =
    \(VersionedFullPackageName fullName) ->
        Http.get
            { url =
                [ "https://package.elm-lang.org/packages/"
                , fullName.author
                , "/"
                , fullName.name
                , "/"
                , fullName.version |> versionToString
                , "/docs.json"
                ]
                    |> String.concat
            , expect = Http.expectJson identity (Json.Decode.list Elm.Docs.decoder)
            }


versionToString : SemanticVersion -> String
versionToString =
    \(SemanticVersion version) ->
        [ version.major, version.minor, version.patch ]
            |> List.map String.fromInt
            |> String.join "."


magnitudeUi : DocsChanges.Magnitude -> Element event_
magnitudeUi =
    \magnitude ->
        magnitude
            |> DocsChanges.magnitudeToString
            |> Element.text
            |> Element.el
                [ Element.Font.italic
                , Element.Font.color (magnitude |> magnitudeToColor)
                ]


addedColor : Element.Color
addedColor =
    Element.rgb 0 1 0


removedColor : Element.Color
removedColor =
    Element.rgb 1 0 0


magnitudeToColor : DocsChanges.Magnitude -> Element.Color
magnitudeToColor =
    \magnitude ->
        case magnitude of
            DocsChanges.Patch ->
                Element.rgb 0 0 1

            DocsChanges.Minor ->
                addedColor

            DocsChanges.Major ->
                removedColor


ui : State -> Browser.Document Event
ui =
    \(State state) ->
        { title = "elm API diff"
        , body =
            (case Maybe.map2 Tuple.pair state.earlier.docs state.later.docs of
                Just ( earlierDocs, laterDocs ) ->
                    let
                        (DocsChanges.PackageChanges packageChanges) =
                            ( earlierDocs, laterDocs ) |> DocsChanges.diff

                        apiIsUnchanged : Bool
                        apiIsUnchanged =
                            (packageChanges.modulesAdded |> List.isEmpty)
                                && (packageChanges.modulesRemoved |> List.isEmpty)
                                && (packageChanges.modulesChanged |> Dict.isEmpty)
                    in
                    if apiIsUnchanged then
                        [ "→ no API changes, so this is a " |> Element.text
                        , DocsChanges.Patch |> magnitudeUi
                        , " version change" |> Element.text
                        ]
                            |> Element.paragraph []

                    else
                        [ [ "→ " |> Element.text
                          , DocsChanges.PackageChanges packageChanges |> DocsChanges.toMagnitude |> magnitudeUi
                          , " version change" |> Element.text
                          ]
                            |> Element.paragraph [ Element.Font.size 23 ]
                        , DocsChanges.PackageChanges packageChanges
                            |> packageChangesUi
                        ]
                            |> Element.column
                                [ Element.spacing 50
                                , Element.height Element.fill
                                , Element.width Element.fill
                                , Element.paddingEach { top = 50, left = 80, right = 40, bottom = 20 }
                                ]
                            |> Element.el
                                [ --Element.scrollbarY
                                  -- , Html.Attributes.style "overflow-y" "auto" |> Element.htmlAttribute
                                  Element.height Element.fill
                                , Element.width Element.fill
                                ]

                Nothing ->
                    [ [ [ "earlier" |> header
                        , state.earlier
                            |> docsJsonSourceUi
                            |> Element.map (\event -> DocsJsonSourceEvent { earlierOrLater = Earlier, event = event })
                        ]
                            |> Element.column
                                [ Element.spacing 20
                                , Element.height Element.fill
                                ]
                      , [ "later" |> header
                        , state.later
                            |> docsJsonSourceUi
                            |> Element.map (\event -> DocsJsonSourceEvent { earlierOrLater = Later, event = event })
                        ]
                            |> List.map (Element.el [ Element.alignTop ])
                            |> Element.column
                                [ Element.spacing 20
                                , Element.height Element.fill
                                ]
                      ]
                        |> Element.row
                            [ Element.spacing 100
                            ]
                    , case state.latestError of
                        Nothing ->
                            Element.none

                        Just error ->
                            ("🚨 " ++ error)
                                |> Element.text
                                |> Element.el [ Element.Font.color (Element.rgb 1 0 0) ]
                    ]
                        |> Element.column
                            [ Element.spacing 80
                            ]
                        |> Element.el [ Element.paddingEach { top = 50, left = 80, right = 40, bottom = 20 } ]
            )
                |> Element.layout
                    [ Element.Background.color (Element.rgb 0 0 0)
                    , Element.Font.color (Element.rgb 1 1 1)
                    ]
                |> List.singleton
        }


elmCodeBlockUi : ElmSyntaxHighlight.SyntaxHighlightable -> Element event_
elmCodeBlockUi elmCode =
    Html.code
        [ Html.Attributes.style "font-size" "0.8em"
        , Html.Attributes.style "line-height" "1.5"
        ]
        [ elmCode |> elmCodeUi ]
        |> Element.html


elmCodeUi : ElmSyntaxHighlight.SyntaxHighlightable -> Html event_
elmCodeUi =
    \syntaxHighlightable ->
        Html.code []
            (syntaxHighlightable
                |> List.map
                    (\segment ->
                        Html.code
                            (case segment.syntaxKind of
                                Nothing ->
                                    []

                                Just syntaxKind ->
                                    [ Html.Attributes.style "color"
                                        (syntaxKind |> syntaxKindToColor |> Color.toCssString)
                                    ]
                            )
                            [ Html.text segment.string
                            ]
                    )
            )


syntaxKindToColor : ElmSyntaxHighlight.SyntaxKind -> Color.Color
syntaxKindToColor =
    -- light purple Color.rgb 0.97 0.42 1
    \syntaxKind ->
        case syntaxKind of
            ElmSyntaxHighlight.Type ->
                Color.rgb 0.9 0.55 1

            ElmSyntaxHighlight.Variant ->
                Color.rgb 0.24 0.75 0.62

            ElmSyntaxHighlight.Field ->
                Color.rgb 0.4 0.9 0

            ElmSyntaxHighlight.ModuleNameOrAlias ->
                Color.rgb 0.45 0.5 1

            ElmSyntaxHighlight.Variable ->
                Color.rgb 0.85 0.8 0.1

            ElmSyntaxHighlight.Flow ->
                Color.rgb 1 0.45 0.35

            ElmSyntaxHighlight.DeclarationRelated ->
                Color.rgb 0.55 0.75 1


{-| Mostly an elm port of <https://github.com/elm/compiler/blob/2f6dd29258e880dbb7effd57a829a0470d8da48b/terminal/src/Diff.hs#L21>
-}
packageChangesUi : DocsChanges.PackageChanges -> Element event_
packageChangesUi =
    \(DocsChanges.PackageChanges changes) ->
        let
            removedChunk : List Chunk
            removedChunk =
                if changes.modulesRemoved |> List.isEmpty then
                    []

                else
                    [ Chunk
                        { title = "removed modules"
                        , magnitude = DocsChanges.Major
                        , details =
                            changes.modulesRemoved
                                |> List.map
                                    (\moduleName ->
                                        [ { string = moduleName, syntaxKind = ElmSyntaxHighlight.ModuleNameOrAlias |> Just } ]
                                            |> elmCodeBlockUi
                                    )
                                |> Element.column [ Element.spacing 0 ]
                        }
                    ]

            addedChunk : List Chunk
            addedChunk =
                if changes.modulesAdded |> List.isEmpty then
                    []

                else
                    [ Chunk
                        { title = "added modules"
                        , magnitude = DocsChanges.Minor
                        , details =
                            changes.modulesAdded
                                |> List.map
                                    (\moduleName ->
                                        [ { string = moduleName, syntaxKind = ElmSyntaxHighlight.ModuleNameOrAlias |> Just } ]
                                            |> elmCodeBlockUi
                                    )
                                |> Element.column [ Element.spacing 0 ]
                        }
                    ]
        in
        [ removedChunk
        , addedChunk
        , changes.modulesChanged |> Dict.toList |> List.map moduleChangesToChunk
        ]
            |> List.concat
            |> List.map (\chunk -> chunk |> chunkToDoc)
            |> Element.column
                [ Element.spacing 40
                , Element.height Element.fill
                ]


chunkToDoc : Chunk -> Element event_
chunkToDoc (Chunk chunk) =
    [ [ (chunk.title ++ " ") |> Element.text
      , chunk.magnitude |> magnitudeUi
      ]
        |> Element.paragraph [ Element.Font.size 23, Element.Font.bold ]
    , chunk.details
        |> Element.map Basics.never
        |> Element.el [ Element.paddingXY 20 30 ]
    ]
        |> Element.column []


moduleChangesToChunk : ( String, DocsChanges.ModuleChanges ) -> Chunk
moduleChangesToChunk ( moduleName, DocsChanges.ModuleChanges moduleChanges ) =
    let
        magnitude : DocsChanges.Magnitude
        magnitude =
            DocsChanges.ModuleChanges moduleChanges |> DocsChanges.moduleChangeToMagnitude

        changesToDocTriple : (k -> v -> Element Never) -> DocsChanges.Changes k v -> ( List (Element Never), List (Element Never), List (Element Never) )
        changesToDocTriple entryToDoc (DocsChanges.Changes changes) =
            let
                diffed : ( k, ( v, v ) ) -> Element Never
                diffed ( name, ( oldValue, newValue ) ) =
                    [ [ "–"
                            |> Element.text
                            |> Element.el
                                [ Element.alignTop
                                , Element.width (Element.px 35)
                                , Element.Font.color removedColor
                                , Element.alignLeft
                                , Element.Font.extraBold
                                , Element.Font.size 27
                                , Element.Font.family [ Element.Font.monospace ]
                                ]
                      , entryToDoc name oldValue
                      ]
                        |> Element.row [ Element.spacing 10 ]
                    , [ "+"
                            |> Element.text
                            |> Element.el
                                [ Element.alignTop
                                , Element.width (Element.px 35)
                                , Element.Font.color addedColor
                                , Element.Font.size 23
                                , Element.Font.family [ Element.Font.monospace ]
                                ]
                      , entryToDoc name newValue
                      ]
                        |> Element.row [ Element.spacing 10 ]
                    ]
                        |> Element.column [ Element.spacing 5 ]
            in
            ( Dict.toList changes.added
                |> List.map (\( name, value ) -> entryToDoc name value)
            , List.map diffed (Dict.toList changes.changed)
            , Dict.toList changes.removed
                |> List.map (\( name, value ) -> entryToDoc name value)
            )

        ( unionAdd, unionChange, unionRemove ) =
            changesToDocTriple unionToDoc moduleChanges.unions

        ( aliasAdd, aliasChange, aliasRemove ) =
            changesToDocTriple aliasToDoc moduleChanges.aliases

        ( valueAdd, valueChange, valueRemove ) =
            changesToDocTriple valueToDoc moduleChanges.values
    in
    Chunk
        { title = moduleName
        , magnitude = magnitude
        , details =
            let
                changesToDoc : ( String, Element.Color ) -> List (Element Never) -> List (Element Never) -> List (Element Never) -> Maybe (Element Never)
                changesToDoc ( categoryName, categoryColor ) unions aliases values =
                    case ( unions, aliases, values ) of
                        ( [], [], [] ) ->
                            Nothing

                        ( unionsPossiblyFilled, aliasesPossiblyFilled, valuesPossiblyFilled ) ->
                            Just
                                ([ categoryName
                                    |> Element.text
                                    |> Element.el
                                        [ Element.Font.size 24
                                        , Element.Font.bold
                                        , Element.Font.color categoryColor
                                        ]
                                 , [ case unionsPossiblyFilled of
                                        [] ->
                                            Element.none

                                        union0 :: union1Up ->
                                            (union0 :: union1Up) |> Element.column [ Element.spacing 20 ]
                                   , case aliasesPossiblyFilled of
                                        [] ->
                                            Element.none

                                        alias0 :: alias1Up ->
                                            (alias0 :: alias1Up)
                                                |> List.map (\el -> el |> Element.el [ Element.paddingEach { left = 0, right = 0, top = 10, bottom = 10 } ])
                                                |> Element.column [ Element.spacing 20 ]
                                   , case valuesPossiblyFilled of
                                        [] ->
                                            Element.none

                                        value0 :: value1Up ->
                                            (value0 :: value1Up) |> Element.column [ Element.spacing 20 ]
                                   ]
                                    |> Element.column
                                        [ Element.spacing 33
                                        , Element.paddingEach { left = 40, right = 5, top = 20, bottom = 40 }
                                        ]
                                 ]
                                    |> Element.column [ Element.spacing 0 ]
                                )
            in
            [ changesToDoc ( "removed", removedColor ) unionRemove aliasRemove valueRemove
            , changesToDoc ( "changed", changedColor ) unionChange aliasChange valueChange
            , changesToDoc ( "added", addedColor ) unionAdd aliasAdd valueAdd
            ]
                |> List.filterMap identity
                |> Element.column [ Element.spacing 10 ]
        }


changedColor : Element.Color
changedColor =
    Element.rgb 1 1 0


unionToDoc : String -> Elm.Docs.Union -> Element event_
unionToDoc _ union =
    case union.tags of
        [] ->
            [ { string = "type", syntaxKind = ElmSyntaxHighlight.DeclarationRelated |> Just }
            , { string = " ", syntaxKind = Nothing }
            , { string = union.name, syntaxKind = ElmSyntaxHighlight.Type |> Just }
            , { string = " ", syntaxKind = Nothing }
            ]
                ++ (union.args
                        |> List.map (\attachment -> { string = attachment, syntaxKind = ElmSyntaxHighlight.Variable |> Just })
                        |> List.intersperse { string = " ", syntaxKind = Nothing }
                   )
                |> elmCodeBlockUi

        _ :: _ ->
            union
                |> docsUnionToSyntax
                |> Elm.Pretty.prettyCustomType
                |> Pretty.pretty 60
                |> ElmSyntaxHighlight.for
                |> elmCodeBlockUi


docsTypeToSyntaxNode : Elm.Type.Type -> Elm.Syntax.Node.Node Elm.Syntax.TypeAnnotation.TypeAnnotation
docsTypeToSyntaxNode =
    \innerDocsType ->
        innerDocsType |> docsTypeToSyntax |> Elm.Syntax.Node.empty


docsUnionToSyntax : Elm.Docs.Union -> Elm.Syntax.Type.Type
docsUnionToSyntax =
    \docsUnion ->
        { documentation = Nothing
        , name = docsUnion.name |> Elm.Syntax.Node.empty
        , generics = docsUnion.args |> List.map Elm.Syntax.Node.empty
        , constructors =
            docsUnion.tags
                |> List.map
                    (\( variantName, variantAttachments ) ->
                        { name = variantName |> Elm.Syntax.Node.empty
                        , arguments = variantAttachments |> List.map docsTypeToSyntaxNode
                        }
                            |> Elm.Syntax.Node.empty
                    )
        }


aliasToDoc : String -> Elm.Docs.Alias -> Element event_
aliasToDoc _ docsAlias =
    docsAlias
        |> docsAliasToSyntax
        |> Elm.Pretty.prettyTypeAlias
        |> Pretty.pretty 110
        |> ElmSyntaxHighlight.for
        |> elmCodeBlockUi


docsAliasToSyntax : Elm.Docs.Alias -> Elm.Syntax.TypeAlias.TypeAlias
docsAliasToSyntax =
    \docsAlias ->
        { documentation = Nothing
        , name = docsAlias.name |> Elm.Syntax.Node.empty
        , generics = docsAlias.args |> List.map Elm.Syntax.Node.empty
        , typeAnnotation = docsAlias.tipe |> docsTypeToSyntaxNode
        }


valueToDoc : String -> Elm.Docs.Value -> Element event_
valueToDoc _ docsValue =
    { name = docsValue.name |> Elm.Syntax.Node.empty
    , typeAnnotation = docsValue.tipe |> docsTypeToSyntaxNode
    }
        |> Elm.Pretty.prettySignature
        |> Pretty.pretty 60
        |> ElmSyntaxHighlight.for
        |> elmCodeBlockUi


header : String -> Element event_
header text =
    text
        |> Element.text
        |> Element.el [ Element.Font.bold, Element.Font.size 24 ]


interactiveColor : Element.Color
interactiveColor =
    Element.rgb 0.3 0.56 0.9


actionUi : String -> Element ()
actionUi label =
    Element.Input.button
        [ Element.Font.color interactiveColor
        , Element.Background.color (Element.rgb 0 0 0)
        ]
        { label = label |> Element.text
        , onPress = () |> Just
        }


docsJsonSourceUi : DocsJsonSourceState -> Element DocsJsonSourceEvent
docsJsonSourceUi =
    \state ->
        case state.docs of
            Nothing ->
                [ Element.row [ Element.spacing 30 ]
                    [ [ "package" |> spanningLabel
                      , [ textInputUi { state = state.packageAuthor, label = "author" }
                            |> Element.map PackageAuthorChanged
                            |> Element.el
                                [ Element.width (Element.fill |> Element.minimum 80)
                                ]
                        , textInputUi { state = state.packageName, label = "name" }
                            |> Element.map PackageNameChanged
                            |> Element.el
                                [ Element.width (Element.fill |> Element.minimum 80)
                                ]
                        ]
                            |> Element.row []
                      ]
                        |> Element.column []
                    , [ "version" |> spanningLabel
                      , [ textInputUi { state = state.versionMajor, label = "major" }
                            |> Element.map VersionMajorChanged
                        , textInputUi { state = state.versionMinor, label = "minor" }
                            |> Element.map VersionMinorChanged
                        , textInputUi { state = state.versionPatch, label = "patch" }
                            |> Element.map VersionPatchChanged
                        ]
                            |> Element.row []
                      ]
                        |> Element.column []
                    ]
                    |> Element.map PackageDocsJsonSourceEvent
                , case { major = state.versionMajor, minor = state.versionMinor, patch = state.versionPatch } |> semanticVersionFromStrings of
                    Ok version ->
                        actionUi "find on package.elm-lang.org"
                            |> Element.map
                                (\() ->
                                    VersionedFullPackageName
                                        { author = state.packageAuthor
                                        , name = state.packageName
                                        , version = version
                                        }
                                        |> DocsRequested
                                )

                    Err error ->
                        error |> Element.text
                , [ "or" |> Element.text
                  , filesSelectUi |> Element.map FilesSelectEvent
                  ]
                    |> Element.row [ Element.spacing 18 ]
                ]
                    |> Element.column [ Element.spacing 20 ]

            Just _ ->
                "✔️ docs.json added" |> Element.text


spanningLabel : String -> Element event_
spanningLabel =
    \text ->
        Element.column
            [ Element.width Element.fill, Element.spacing 4 ]
            [ text |> Element.text
            , Element.none
            ]


textInputUi : { state : String, label : String } -> Element String
textInputUi config =
    Element.Input.text
        [ Element.Border.color (Element.rgba 0 0 0 0)
        , Element.paddingXY 0 4
        , Element.Font.size 20
        , Element.Font.family [ Element.Font.monospace ]
        , Element.Font.color interactiveColor
        , Element.Border.rounded 0
        , Element.Background.color (Element.rgb 0 0 0)
        ]
        { onChange = identity
        , text = config.state
        , placeholder = Nothing
        , label =
            Element.Input.labelAbove
                []
                (config.label
                    |> Element.text
                    |> Element.el
                        [ Element.Font.size 14
                        , Element.Font.family [ Element.Font.sansSerif ]
                        ]
                )
        }
        |> Element.el [ Element.paddingEach { top = 0, left = 0, right = 10, bottom = 0 } ]


semanticVersionFromStrings : { major : String, minor : String, patch : String } -> Result String SemanticVersion
semanticVersionFromStrings =
    \raw ->
        case ( raw.major |> String.toInt, ( raw.minor |> String.toInt, raw.patch |> String.toInt ) ) of
            ( Just versionMajor, ( Just versionMinor, Just versionPatch ) ) ->
                SemanticVersion { major = versionMajor, minor = versionMinor, patch = versionPatch }
                    |> Ok

            _ ->
                "version parts need to be natural numbers >= 0" |> Err


filesSelectUi : Element FilesSelectEvent
filesSelectUi =
    actionUi "select docs.json file"
        |> Element.map (\() -> FilesSelectClicked)
        |> Element.el
            [ Html.Events.preventDefaultOn "drop"
                (Json.Decode.map (\files -> ( files |> FilesDropped, True ))
                    dropFilesJsonDecoder
                )
                |> Element.htmlAttribute
            ]


dropFilesJsonDecoder : Json.Decode.Decoder File
dropFilesJsonDecoder =
    Json.Decode.at [ "dataTransfer", "files" ]
        (Json.Decode.oneOrMore (\head _ -> head)
            File.decoder
        )


type VersionedFullPackageName
    = VersionedFullPackageName { author : String, name : String, version : SemanticVersion }


type SemanticVersion
    = SemanticVersion { major : Int, minor : Int, patch : Int }


type Chunk
    = Chunk
        { title : String
        , magnitude : DocsChanges.Magnitude
        , details : Element Never
        }


docsTypeToSyntax : Elm.Type.Type -> Elm.Syntax.TypeAnnotation.TypeAnnotation
docsTypeToSyntax =
    \tipe ->
        case tipe of
            Elm.Type.Var name ->
                Elm.Syntax.TypeAnnotation.GenericType name

            Elm.Type.Lambda input output ->
                Elm.Syntax.TypeAnnotation.FunctionTypeAnnotation (input |> docsTypeToSyntaxNode) (output |> docsTypeToSyntaxNode)

            Elm.Type.Tuple [] ->
                Elm.Syntax.TypeAnnotation.Unit

            Elm.Type.Tuple parts ->
                Elm.Syntax.TypeAnnotation.Tupled (parts |> List.map docsTypeToSyntaxNode)

            Elm.Type.Type unqualifiedName arguments ->
                Elm.Syntax.TypeAnnotation.Typed
                    (( [], unqualifiedName ) |> Elm.Syntax.Node.empty)
                    (arguments |> List.map docsTypeToSyntaxNode)

            Elm.Type.Record fields (Just extendedRecordVariableName) ->
                Elm.Syntax.TypeAnnotation.GenericRecord
                    (extendedRecordVariableName |> Elm.Syntax.Node.empty)
                    (fields
                        |> List.map
                            (\( fieldName, fieldValue ) ->
                                ( fieldName |> Elm.Syntax.Node.empty, fieldValue |> docsTypeToSyntaxNode )
                                    |> Elm.Syntax.Node.empty
                            )
                        |> Elm.Syntax.Node.empty
                    )

            Elm.Type.Record fields Nothing ->
                Elm.Syntax.TypeAnnotation.Record
                    (fields
                        |> List.map
                            (\( fieldName, fieldValue ) ->
                                ( fieldName |> Elm.Syntax.Node.empty, fieldValue |> docsTypeToSyntaxNode )
                                    |> Elm.Syntax.Node.empty
                            )
                    )


type FilesSelectEvent
    = FilesDropped File
    | FilesSelectClicked