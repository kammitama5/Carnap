{-#LANGUAGE DeriveGeneric #-}
module Handler.Admin where

import Import
import Util.Data
import Util.Database
import Yesod.Form.Bootstrap3
import Yesod.Form.Jquery
import Text.Blaze.Html (toMarkup)
import Data.Aeson (decode,encode)
import Data.Time
import System.FilePath
import System.Directory (getDirectoryContents,removeFile, doesFileExist)

deleteAdminR :: Handler Value
deleteAdminR = do
        msg <- requireJsonBody :: Handler AdminDelete
        case msg of
            DowngradeInstructor uid -> do
                mud <- runDB $ get uid
                case mud of 
                    Just ud -> case userDataInstructorId ud of
                                   Just iid -> do runDB $ do cids <- map entityKey <$> selectList [CourseInstructor ==. iid] []
                                                             students <- concat <$> mapM (\cid -> selectList [UserDataEnrolledIn ==. Just cid] []) cids
                                                             mapM (\student -> update (entityKey student) [UserDataEnrolledIn =. Nothing]) students
                                                             update uid [UserDataInstructorId =. Nothing]
                                                             deleteCascade iid
                                                  returnJson ("Downgraded!" :: Text)
                                   Nothing -> returnJson ("Not an instructor" :: Text)
            _ -> returnJson ("Bad Message" :: Text)

postAdminR :: Handler Html
postAdminR = do allUserData <- runDB $ selectList [] []
                let allStudentsData = filter (\x -> userDataInstructorId (entityVal x) == Nothing) allUserData
                    allStudentUids = map (userDataUserId . entityVal) allStudentsData
                students <- catMaybes <$> mapM (\x -> runDB (get x)) allStudentUids
                ((upgraderslt,upgradeWidget),enctypeUpgrade) <- runFormPost (upgradeToInstructor students)
                case upgraderslt of 
                     (FormSuccess ident) -> do 
                            success <- runDB $ do imd <- insert InstructorMetadata
                                                  muent <- getBy $ UniqueUser ident
                                                  mudent <- case entityKey <$> muent of
                                                                Just uid -> getBy $ UniqueUserData uid
                                                                Nothing -> return Nothing
                                                  case entityKey <$> mudent of 
                                                       Nothing -> return False
                                                       Just udid -> do update udid [UserDataInstructorId =. Just imd]
                                                                       return True
                            if success then setMessage $ "user " ++ (toMarkup ident) ++ " upgraded to instructor"
                                       else setMessage $ "couldn't upgrade user " ++ (toMarkup ident) ++ " to instructor"
                     (FormFailure s) -> setMessage $ "Something went wrong: " ++ toMarkup (show s)
                     FormMissing -> setMessage "Submission data incomplete"
                redirect AdminR --XXX: redirect here to make sure changes are visually reflected

getAdminR :: Handler Html
getAdminR = do allUserData <- runDB $ selectList [] []
               let allInstructorsData = filter (\x -> userDataInstructorId (entityVal x) /= Nothing) allUserData
                   allStudentsData = filter (\x -> userDataInstructorId (entityVal x) == Nothing) allUserData
                   allInstructorUids = map (userDataUserId .entityVal)  allInstructorsData
                   allStudentUids = map (userDataUserId . entityVal) allStudentsData
               instructors <- catMaybes <$> mapM (\x -> runDB (get x)) allInstructorUids
               students <- catMaybes <$> mapM (\x -> runDB (get x)) allStudentUids
               instructorW <- instructorWidget instructors allInstructorsData
               unenrolledW <- unenrolledWidget allStudentsData
               (upgradeWidget,enctypeUpgrade) <- generateFormPost (upgradeToInstructor students)
               defaultLayout $ do 
                             toWidgetHead [julius|
                                function tryDelete (ident, json) {
                                    if (ident == prompt("Are you sure you want to downgrade this instructor?\nAll their data will be lost. Enter their ident to confirm.")) {
                                       adminDelete(json);
                                    } else { 
                                       alert("Wrong Ident!");
                                    }
                                };

                                function adminDelete (json) {
                                    jQuery.ajax({
                                        url: '@{AdminR}',
                                        type: 'DELETE',
                                        contentType: "application/json",
                                        data: json,
                                        success: function(data) {
                                            window.alert(data);
                                            location.reload()
                                            },
                                        error: function(data) {
                                            window.alert("Error, couldn't delete")
                                            },
                                    });
                                };
                             |]
                             [whamlet|
                              <div.container>
                                  <h1> Admin Portal
                                  ^{instructorW}
                                  ^{unenrolledW}
                                  <form method=post enctype=#{enctypeUpgrade}>
                                      ^{upgradeWidget}
                                       <div.form-group>
                                           <input.btn.btn-primary type=submit value="upgrade">
                             |]

upgradeToInstructor users = renderBootstrap3 BootstrapBasicForm $
                                areq (selectFieldList userIdents) (bfs ("Upgrade User to Instructor" :: Text)) Nothing
        where userIdents = let idents = map userIdent users in zip idents idents

unenrolledWidget :: [Entity UserData] -> HandlerT App IO Widget
unenrolledWidget students = do let unenrolledData = filter (\x -> userDataEnrolledIn (entityVal x) == Nothing) students
                               unenrolled <- catMaybes <$> mapM (\ud -> runDB $ get (userDataUserId (entityVal ud))) unenrolledData
                               return [whamlet|
                                    <div.card style="margin-bottom:20px">
                                        <div.card-header> Unenrolled Students
                                        <div.card-block>
                                          <table.table.table-striped>
                                                <thead>
                                                    <th> Ident
                                                    <th> Name
                                                <tbody>
                                                    $forall (User ident _, Entity _ (UserData fn ln _ _ _)) <- zip unenrolled unenrolledData

                                                        <tr>
                                                            <td>
                                                                <a href=@{UserR ident}>#{ident}
                                                            <td>
                                                                #{ln}, #{fn}
                                    |]


instructorWidget :: [User] -> [Entity UserData] -> HandlerT App IO Widget
instructorWidget insts idata = do courses <- mapM getCoursesWithEnrollment (map entityVal idata)
                                  return [whamlet|
                                        $forall (instructor, Entity key (UserData fn ln _ _ _), courses) <- zip3 insts idata courses
                                            <div.card style="margin-bottom:20px">
                                                <div.card-header>
                                                    <a href=@{UserR (userIdent instructor)}>#{userIdent instructor}
                                                    — #{fn} #{ln}
                                                <div.card-block>
                                                      $forall (course, enrollment) <- courses
                                                          <h3> #{courseTitle (entityVal course)}
                                                          <table.table.table-striped>
                                                            <thead>
                                                                <th> Name
                                                            <tbody>
                                                                $forall UserData sfn sln _ _ _ <- map entityVal enrollment
                                                                    <tr>
                                                                        <td>
                                                                            #{sln}, #{sfn}
                                                    <button.btn.btn-sm.btn-danger type="button" onclick="tryDelete('#{userIdent instructor}', '#{decodeUtf8 $ encode $ DowngradeInstructor key}')">
                                                        Downgrade Instructor
                                  |]
    where getCoursesWithEnrollment ud = case userDataInstructorId ud of 
                                            Just iid -> do courseEnt <- runDB $ selectList [CourseInstructor ==. iid] []
                                                           enrollments <- mapM (\c -> runDB $ selectList [UserDataEnrolledIn ==. Just (entityKey c)] []) courseEnt
                                                           return $ zip courseEnt enrollments

                                            Nothing -> return []

data AdminDelete = DowngradeInstructor UserDataId
    deriving Generic

instance ToJSON AdminDelete

instance FromJSON AdminDelete
